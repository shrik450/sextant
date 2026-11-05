import Foundation

private func isIdentifierUnit(_ u: unichar) -> Bool {
    guard let s = UnicodeScalar(u) else { return false }
    return CharacterSet.alphanumerics.contains(s) || s == "_" || s == "$"
}

private func isDigit(_ u: unichar) -> Bool { u >= 0x30 && u <= 0x39 }

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
    let skipped = tokens.filter { [.keyword, .comment, .string, .number].contains($0.kind) }.map(\.range)
    var out: [NSRange] = []
    var i = 0
    while i < s.length {
        guard isIdentifierUnit(s.character(at: i)) else { i += 1; continue }
        let start = i
        while i < s.length, isIdentifierUnit(s.character(at: i)) { i += 1 }
        let r = NSRange(location: start, length: i - start)
        if !isDigit(s.character(at: start)), !skipped.contains(where: { NSIntersectionRange($0, r).length > 0 }) { out.append(r) }
    }
    return out
}

/// Returns the column where the caret lands on a line.
///
/// That's the first identifier the change touched, else the first identifier, else the first
/// character that isn't a space.
///
/// - Parameters:
///   - text: The line.
///   - tokens: The line's syntax tokens.
///   - changed: The ranges of the line's changed words.
/// - Returns: A UTF-16 offset into `text`.
public func landingColumn(in text: String, tokens: [Token], changed: [NSRange]) -> Int {
    let names = identifiers(in: text, tokens: tokens)
    if let touched = names.first(where: { n in changed.contains { NSIntersectionRange($0, n).length > 0 } }) { return touched.location }
    if let first = names.first { return first.location }
    let s = text as NSString
    var i = 0
    while i < s.length, s.character(at: i) == 0x20 || s.character(at: i) == 0x09 { i += 1 }
    return i == s.length ? 0 : i
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

/// Returns a key for one run of changed lines in a file.
///
/// The key starts with the file's review key, so it changes whenever the file's change does.
///
/// - Parameters:
///   - file: The file's `RawChange.reviewKey`.
///   - lines: The run's lines.
public func changeKey(file: String, lines: some Sequence<DiffLine>) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    func mix(_ bytes: some Sequence<UInt8>) {
        for b in bytes {
            hash ^= UInt64(b)
            hash = hash &* 0x100000001b3
        }
    }
    for l in lines {
        mix([l.kind == .added ? 0x2b : l.kind == .deleted ? 0x2d : 0x20])
        mix(l.text.utf8)
        mix([0x0a])
    }
    return file + "#" + String(hash, radix: 16)
}

/// What has been read and reviewed in a repository.
///
/// A file is reviewed as a whole, and its runs of changes are read one by one. Reviewing a file
/// reads all of its changes, reading the last unread change reviews the file, and unreading a
/// change or unreviewing the file undoes that.
public struct ReadingState: Equatable, Sendable {
    /// The review keys of reviewed files.
    public private(set) var reviewed: Set<String>
    /// The keys of changes read in files that aren't reviewed.
    public private(set) var read: Set<String>

    public init(reviewed: Set<String> = [], read: Set<String> = []) {
        self.reviewed = reviewed
        self.read = read
    }

    public func isReviewed(_ file: String) -> Bool { reviewed.contains(file) }

    public func isRead(_ change: String, in file: String) -> Bool { reviewed.contains(file) || read.contains(change) }

    /// Marks one change of a file read or unread.
    ///
    /// - Parameters:
    ///   - change: The change's key.
    ///   - file: The file's review key.
    ///   - all: The keys of every change in the file.
    public mutating func setRead(_ change: String, in file: String, all: [String], to value: Bool) {
        if value {
            read.insert(change)
            if all.allSatisfy(read.contains) { setReviewed([file], to: true) }
        } else {
            if reviewed.remove(file) != nil { read.formUnion(all) }
            read.remove(change)
        }
    }

    /// Marks files reviewed or not, reading or unreading all of their changes.
    public mutating func setReviewed(_ files: [String], to value: Bool) {
        for f in files {
            if value { reviewed.insert(f) } else { reviewed.remove(f) }
        }
        let prefixes = files.map { $0 + "#" }
        read = read.filter { k in !prefixes.contains { k.hasPrefix($0) } }
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
