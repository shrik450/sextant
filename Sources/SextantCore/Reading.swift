import Foundation

private let alphanumerics = CharacterSet.alphanumerics

/// Returns whether a UTF-16 unit can be part of an identifier: a letter, mark or digit, `_` or
/// `$`.
///
/// A surrogate is never part of one, since it's half a character.
public func isIdentifierUnit(_ u: unichar) -> Bool {
    if u < 0x80 {
        let lower = u | 0x20
        return (u >= 0x30 && u <= 0x39) || (lower >= 0x61 && lower <= 0x7A) || u == 0x5F || u == 0x24
    }
    guard let s = UnicodeScalar(u) else { return false }
    return alphanumerics.contains(s)
}

private func isDigit(_ u: unichar) -> Bool { u >= 0x30 && u <= 0x39 }

/// Reads a range of a string's UTF-16 units from front to back, a chunk at a time, so reading
/// a unit costs neither a message send nor an allocation.
///
/// - Parameters:
///   - string: The string.
///   - range: The UTF-16 range to read.
///   - body: Takes each chunk in turn, and returns whether to go on.
private func forEachChunk(of string: NSString, range: NSRange, _ body: (UnsafeBufferPointer<unichar>) -> Bool) {
    guard range.length > 0 else { return }
    let size = min(range.length, 4096)
    withUnsafeTemporaryAllocation(of: unichar.self, capacity: size) { buffer in
        var start = range.location
        let end = NSMaxRange(range)
        while start < end {
            let count = min(size, end - start)
            string.getCharacters(buffer.baseAddress!, range: NSRange(location: start, length: count))
            guard body(UnsafeBufferPointer(rebasing: buffer[..<count])) else { return }
            start += count
        }
    }
}

/// Tells whether any of some ranges intersects a range, for ranges asked about in order: each
/// starting no earlier, and ending no earlier, than the one before.
///
/// Asking costs nothing beyond one pass over the ranges, whatever the number of questions.
struct OrderedIntersections {
    private let ranges: [NSRange]
    private var next = 0
    /// The furthest end of the ranges that start before the end of the range asked about last.
    private var reach = Int.min

    init(_ ranges: some Sequence<NSRange>) {
        let nonEmpty = ranges.filter { $0.length > 0 }
        self.ranges = nonEmpty.indices.dropFirst().allSatisfy { nonEmpty[$0 - 1].location <= nonEmpty[$0].location }
            ? nonEmpty
            : nonEmpty.sorted { $0.location < $1.location }
    }

    /// Returns whether any range shares a unit with `r`, which must not be empty.
    mutating func intersect(_ r: NSRange) -> Bool {
        let end = NSMaxRange(r)
        while next < ranges.count, ranges[next].location < end {
            reach = max(reach, NSMaxRange(ranges[next]))
            next += 1
        }
        return reach > r.location
    }

    /// Returns whether no range shares a unit with `r` or anything after it.
    func isPassed(by r: NSRange) -> Bool { next == ranges.count && reach <= r.location }
}

/// Calls `body` with the identifiers in a line of code that name something, in order, until it
/// returns false.
///
/// Keywords, comments, strings and numbers are left out, so stepping through a line goes from
/// name to name. Costs one pass over the line and its tokens.
///
/// - Parameters:
///   - text: The text the line is in.
///   - range: The line's UTF-16 range in `text`.
///   - tokens: The line's syntax tokens, with UTF-16 ranges from the start of the line.
///   - body: Takes each identifier's UTF-16 range from the start of the line, and returns
///     whether to go on.
public func forEachIdentifier(in text: NSString, range: NSRange, tokens: [Token], _ body: (NSRange) -> Bool) {
    var skipped = OrderedIntersections(tokens.lazy.filter(\.kind.isSkippedByNames).map(\.range))
    var start: Int?
    var startsWithDigit = false
    var offset = 0
    var goOn = true
    func found(_ start: Int, _ end: Int) -> Bool {
        let r = NSRange(location: start, length: end - start)
        return skipped.intersect(r) || body(r)
    }
    forEachChunk(of: text, range: range) { chunk in
        var at = offset
        var current = start
        defer {
            offset = at
            start = current
        }
        for u in chunk {
            if isIdentifierUnit(u) {
                if current == nil {
                    current = at
                    startsWithDigit = isDigit(u)
                }
            } else if let s = current {
                current = nil
                if !startsWithDigit, !found(s, at) {
                    goOn = false
                    return false
                }
            }
            at += 1
        }
        return true
    }
    if goOn, let s = start, !startsWithDigit { _ = found(s, offset) }
}

/// Returns the identifiers in a line of code that name something.
///
/// Keywords, comments, strings and numbers are left out, so stepping through a line goes from
/// name to name.
///
/// - Parameters:
///   - text: The line.
///   - tokens: The line's syntax tokens, with UTF-16 ranges into `text`.
/// - Returns: The identifiers' UTF-16 ranges, in order.
public func identifiers(in text: String, tokens: [Token]) -> [NSRange] {
    let s = text as NSString
    var out: [NSRange] = []
    forEachIdentifier(in: s, range: NSRange(location: 0, length: s.length), tokens: tokens) { out.append($0); return true }
    return out
}

/// Returns the column where the caret lands on a line.
///
/// That's the first identifier the change touched, else the first identifier, else the first
/// character that isn't a space. Reads the line only as far as it needs to.
///
/// - Parameters:
///   - text: The text the line is in.
///   - range: The line's UTF-16 range in `text`.
///   - tokens: The line's syntax tokens, with UTF-16 ranges from the start of the line.
///   - changed: The ranges of the line's changed words, from the start of the line.
/// - Returns: A UTF-16 offset from the start of the line.
public func landingColumn(in text: NSString, range: NSRange, tokens: [Token], changed: [NSRange]) -> Int {
    var touched = OrderedIntersections(changed)
    var first: Int?
    var landing: Int?
    forEachIdentifier(in: text, range: range, tokens: tokens) { r in
        if first == nil { first = r.location }
        if touched.intersect(r) {
            landing = r.location
            return false
        }
        return !touched.isPassed(by: r)
    }
    if let column = landing ?? first { return column }
    var i = 0
    var column = 0
    forEachChunk(of: text, range: range) { chunk in
        for u in chunk {
            guard u == 0x20 || u == 0x09 else {
                column = i
                return false
            }
            i += 1
        }
        return true
    }
    return column
}

/// Returns the range of the identifier at or just before a UTF-16 offset in a text: a run of
/// letters, marks, digits, `_` and `$`.
public func identifier(at index: Int, in text: NSString) -> NSRange? {
    guard text.length > 0 else { return nil }
    func isIdentifier(_ i: Int) -> Bool { i >= 0 && i < text.length && isIdentifierUnit(text.character(at: i)) }
    var i = min(index, text.length - 1)
    if !isIdentifier(i) { i -= 1 }
    guard isIdentifier(i) else { return nil }
    var lo = i, hi = i
    while isIdentifier(lo - 1) { lo -= 1 }
    while isIdentifier(hi + 1) { hi += 1 }
    return NSRange(location: lo, length: hi - lo + 1)
}

extension TokenKind {
    /// Whether names leave out what a token of this kind covers: keywords, comments, strings and
    /// numbers.
    var isSkippedByNames: Bool {
        switch self {
        case .keyword, .comment, .string, .number: true
        default: false
        }
    }
}

/// Returns where a word appears on its own in a text, not as part of a longer identifier.
public func wholeWordMatches(of word: String, in text: String) -> [NSRange] {
    let s = text as NSString
    let w = (word as NSString).length
    guard w > 0 else { return [] }
    var out: [NSRange] = []
    var from = 0
    while from < s.length {
        let r = s.range(of: word, options: .literal, range: NSRange(location: from, length: s.length - from))
        guard r.location != NSNotFound else { break }
        let before = r.location > 0 && isIdentifierUnit(s.character(at: r.location - 1))
        let after = NSMaxRange(r) < s.length && isIdentifierUnit(s.character(at: NSMaxRange(r)))
        if !before && !after { out.append(r) }
        from = r.location + 1
    }
    return out
}

/// A place a typed jump can land: a line, by its index in the lines searched, and a UTF-16 column.
public struct JumpTarget: Equatable, Sendable {
    public var line: Int
    public var column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }
}

/// Finds where some typed text appears in lines, for jumping straight to it.
///
/// The match ignores case unless the typed text has a capital letter.
public func jumpTargets(for query: String, in lines: [String]) -> [JumpTarget] {
    guard !query.isEmpty else { return [] }
    let options: NSString.CompareOptions = query.contains(where: \.isUppercase) ? .literal : [.literal, .caseInsensitive]
    var out: [JumpTarget] = []
    for (i, line) in lines.enumerated() {
        let s = line as NSString
        var from = 0
        while from < s.length {
            let r = s.range(of: query, options: options, range: NSRange(location: from, length: s.length - from))
            guard r.location != NSNotFound else { break }
            out.append(JumpTarget(line: i, column: r.location))
            from = r.location + 1
        }
    }
    return out
}

/// Returns labels to pick one of `count` jump targets with: a key each while there are enough
/// keys, home row first, then two keys each.
public func jumpLabels(_ count: Int) -> [String] {
    let keys = Array("asdfghjklqwertyuiopzxcvbnm").map(String.init)
    if count <= keys.count { return Array(keys.prefix(count)) }
    return Array(keys.lazy.flatMap { a in keys.map { a + $0 } }.prefix(count))
}

/// Returns a key for each run of changed lines in a file, which no other run in the file has.
///
/// A run's key comes from its lines, with their endings, and from how many runs with the same
/// lines come before it, so runs with the same lines have keys of their own. Nothing else goes
/// into it, so a run has the same key in the hunks and in the whole file, and keeps it however
/// the file changes elsewhere, unless a run with the same lines comes or goes before it.
///
/// - Parameters:
///   - lines: The file's lines.
///   - runs: The runs of changes in `lines`, in order.
/// - Returns: Each run's key, in the order of `runs`.
public func changeKeys(_ lines: [DiffLine], runs: [ChangeRun]) -> [String] {
    var seen: [UInt64: Int] = [:]
    return runs.map { run in
        var hash: UInt64 = 0xcbf29ce484222325
        func mix(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        for l in lines[run.lines] {
            mix(l.kind == .added ? 0x2b : l.kind == .deleted ? 0x2d : 0x20)
            for b in l.text.utf8 { mix(b) }
            if l.carriageReturn { mix(0x0d) }
            if l.noNewline { mix(0x5c) }
            mix(0x0a)
        }
        let earlier = seen[hash, default: 0]
        seen[hash] = earlier + 1
        return String(hash, radix: 16) + (earlier == 0 ? "" : "-\(earlier)")
    }
}

/// What has been read and reviewed in a repository.
///
/// A file is reviewed as a whole, by the change that made it (`RawChange.reviewKey`), and its
/// runs of changes are read one by one. Reviewing a file reads all of its changes, reading the
/// last unread change reviews the file, and unreading a change or unreviewing the file undoes
/// that.
///
/// Changes are read in the file a change starts from (`RawChange.readingKey`) rather than in
/// the change, so once the file changes elsewhere, as it does while an agent works on it, it's
/// no longer reviewed but the changes read in it stay read.
public struct ReadingState: Equatable, Sendable {
    /// The review keys of reviewed files.
    public private(set) var reviewed: Set<String>
    /// The keys of read changes, by the reading key of the file they're in.
    public private(set) var read: [String: Set<String>]

    public init(reviewed: Set<String> = [], read: [String: Set<String>] = [:]) {
        self.reviewed = reviewed
        self.read = read
    }

    public func isReviewed(_ file: RawChange) -> Bool { reviewed.contains(file.reviewKey) }

    public func isRead(_ change: String, in file: RawChange) -> Bool {
        isReviewed(file) || read[file.readingKey]?.contains(change) == true
    }

    /// Marks one change of a file read or unread.
    ///
    /// - Parameters:
    ///   - change: The change's key, from `changeKeys(_:runs:)`.
    ///   - file: The file's change.
    ///   - all: The keys of every change in the file.
    public mutating func setRead(_ change: String, in file: RawChange, all: [String], to value: Bool) {
        let key = file.readingKey
        if value {
            read[key, default: []].insert(change)
            if !all.isEmpty, all.allSatisfy({ read[key]?.contains($0) == true }) { reviewed.insert(file.reviewKey) }
        } else {
            if reviewed.remove(file.reviewKey) != nil { read[key, default: []].formUnion(all) }
            read[key]?.remove(change)
            if read[key]?.isEmpty == true { read[key] = nil }
        }
    }

    /// Marks files reviewed or not, reading or unreading all of their changes.
    ///
    /// - Parameters:
    ///   - files: The files' changes.
    ///   - value: Whether they're reviewed.
    ///   - changes: The keys of the changes in each file, where they're known, which a file
    ///     reviewed keeps read once it changes elsewhere. Files that can't change, such as a
    ///     commit's, don't need them.
    public mutating func setReviewed(_ files: [RawChange], to value: Bool, changes: [RawChange: [String]] = [:]) {
        for f in files {
            if value {
                reviewed.insert(f.reviewKey)
                if let keys = changes[f], !keys.isEmpty { read[f.readingKey, default: []].formUnion(keys) }
            } else {
                reviewed.remove(f.reviewKey)
                read[f.readingKey] = nil
            }
        }
    }
}

/// Returns the indices where each run of changed rows starts.
///
/// - Parameter changed: Whether each row is part of a change.
public func changeStarts(_ changed: some Sequence<Bool>) -> [Int] {
    var starts: [Int] = []
    var previous = false
    for (i, c) in changed.enumerated() {
        if c && !previous { starts.append(i) }
        previous = c
    }
    return starts
}

/// Returns which change a row is in or below, counting from 1, or 0 above the first change.
///
/// - Parameters:
///   - row: The row, such as the caret's.
///   - starts: The sorted rows where each change starts.
public func changeOrdinal(atRow row: Int, starts: [Int]) -> Int {
    var low = 0, high = starts.count
    while low < high {
        let mid = (low + high) / 2
        if starts[mid] <= row { low = mid + 1 } else { high = mid }
    }
    return low
}

/// Returns the line numbers and code that some of a diff's lines are, on one side, for a
/// reference such as `path:3-5` or a note.
///
/// - Parameters:
///   - indices: The lines, by index into `lines`.
///   - lines: The diff's lines.
///   - old: The side to name, as the column the lines were picked in says; nil to name the old
///     side when no picked line was added and some were removed, and the new side otherwise.
/// - Returns: The range of line numbers, whether they're the old side's, and the code of the
///   lines on that side, or nil if none of them is on it.
public func referencedLines(_ indices: [Int], in lines: [DiffLine], old: Bool?) -> (lines: ClosedRange<Int>, old: Bool, code: [String])? {
    let picked = indices.filter { lines.indices.contains($0) }
    let old = old ?? (!picked.contains { lines[$0].kind == .added } && picked.contains { lines[$0].kind == .deleted })
    let kept = picked.filter { lines[$0].kind != (old ? .added : .deleted) }
    let numbers = kept.map { old ? lines[$0].oldNo : lines[$0].newNo }
    guard let lo = numbers.min(), let hi = numbers.max() else { return nil }
    return (lo...hi, old, kept.map { lines[$0].text })
}
