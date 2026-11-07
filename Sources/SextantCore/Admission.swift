import Foundation
import Synchronization

/// The limits on what Sextant takes in of a file, so no file, however large or strange, makes
/// the app hang or fill memory, or shows less than the app says.
public enum ContentLimits {
    /// The most UTF-8 bytes of a side of a file analyzed for colours, definitions and names.
    public static let analysisBytes = 2 << 20
    /// The longest line, in UTF-16 units, of a file analyzed. Lines longer than this are
    /// minified or generated, and slow to parse, lay out and search.
    public static let analysisLineWidth = 20_000
    /// The most of a line taken in, in UTF-16 units. The rest is left out, and the reader says
    /// how much.
    public static let lineWidth = analysisLineWidth
    /// The most bytes of a side of a file shown whole, and compared by git.
    public static let wholeBytes = 50 << 20
    /// The most lines of a file shown whole.
    public static let wholeLines = 500_000
    /// The most lines of a file that's too large to show whole taken in as its preview.
    public static let previewLines = 10_000
    /// The most bytes of a file that's too large to show whole read for its preview.
    public static let previewBytes = 1 << 20
    /// The most bytes of text analyzed at once, across every analysis (see `AnalysisGate`).
    public static let analysisInFlight = 8 << 20
    /// The longest a parse and the queries over its tree may run before they're abandoned.
    public static let analysisTime: Duration = .seconds(10)
    /// The most captures one query run over a file takes before it stops.
    public static let capturesPerQuery = 2_000_000
}

/// What Sextant takes in of one version of a file, decided once from its size and shape.
public struct Admission: Sendable, Hashable {
    /// UTF-8 bytes, with a line ending for each line.
    public var bytes: Int
    public var lines: Int
    /// The longest line's length in UTF-16 units, or its length in bytes when that's within
    /// `ContentLimits.analysisLineWidth` and the exact count doesn't matter.
    public var longestLine: Int
    /// Whether git would take the contents for binary: a NUL among the first 8,000 bytes.
    public var isBinary: Bool

    public init(bytes: Int, lines: Int, longestLine: Int, isBinary: Bool = false) {
        self.bytes = bytes
        self.lines = lines
        self.longestLine = longestLine
        self.isBinary = isBinary
    }

    /// What the app does with contents.
    public enum Verdict: Sendable, Hashable {
        /// Shown whole, and analyzed for colours, definitions and names.
        case analyzed
        /// Shown whole as plain text, since it's too large or its lines too long to analyze.
        case plain
        /// Too large to show whole: only a bounded part of it shows.
        case preview
        case binary
    }

    public var verdict: Verdict {
        if isBinary { return .binary }
        if bytes > ContentLimits.wholeBytes || lines > ContentLimits.wholeLines { return .preview }
        if bytes > ContentLimits.analysisBytes || longestLine > ContentLimits.analysisLineWidth { return .plain }
        return .analyzed
    }

    /// Whether the contents are analyzed.
    public var analyzes: Bool { verdict == .analyzed }

    /// Whether the contents show whole.
    public var showsWhole: Bool { verdict == .analyzed || verdict == .plain }

    /// Combines the admissions of a file's two sides: what the larger takes.
    public func joined(_ other: Admission) -> Admission {
        Admission(bytes: max(bytes, other.bytes), lines: max(lines, other.lines), longestLine: max(longestLine, other.longestLine),
                  isBinary: isBinary || other.isBinary)
    }

    /// Why the contents don't show whole, or aren't analyzed, in words for the reader; nil when
    /// they're shown and analyzed.
    public var reason: String? {
        switch verdict {
        case .analyzed, .binary:
            return nil
        case .preview:
            if bytes > ContentLimits.wholeBytes { return "the file is \(byteCount(bytes)), more than the \(byteCount(ContentLimits.wholeBytes)) shown whole" }
            return "the file has \(count(lines)) lines, more than the \(count(ContentLimits.wholeLines)) shown whole"
        case .plain:
            if bytes > ContentLimits.analysisBytes { return "the text is \(byteCount(bytes)), more than the \(byteCount(ContentLimits.analysisBytes)) analyzed" }
            return "a line is longer than \(count(ContentLimits.analysisLineWidth)) characters"
        }
    }

    /// Measures contents as `splitLines(_:)` would split them, in one pass over the bytes.
    public init(measuring data: Data) {
        var lines = 0, longest = 0
        let binary = data.prefix(8000).contains(0)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let count = raw.count
            var start = 0
            while start < count {
                let found = memchr(base + start, 0x0A, count - start)
                let end = found.map { base.distance(to: UnsafeRawPointer($0)) } ?? count
                var length = end - start
                if length > 0, raw[end - 1] == 0x0D { length -= 1 }
                if length > longest {
                    let width = length > ContentLimits.analysisLineWidth
                        ? utf16Count(UnsafeRawBufferPointer(rebasing: raw[start..<start + length]))
                        : length
                    longest = max(longest, width)
                }
                lines += 1
                start = end + 1
            }
        }
        self.init(bytes: data.count + (data.last == 0x0A || data.isEmpty ? 0 : 1), lines: lines, longestLine: longest, isBinary: binary)
    }

    /// Measures one side of some lines.
    public init<S: Sequence>(measuringLines lines: S) where S.Element == String {
        var bytes = 0, count = 0, longest = 0
        for l in lines {
            let n = l.utf8.count
            bytes += n + 1
            count += 1
            if n > longest { longest = max(longest, n > ContentLimits.analysisLineWidth ? l.utf16.count : n) }
        }
        self.init(bytes: bytes, lines: count, longestLine: longest)
    }
}

/// Counts the UTF-16 units UTF-8 bytes decode to.
private func utf16Count(_ bytes: UnsafeRawBufferPointer) -> Int {
    var n = 0
    for b in bytes {
        if b & 0xC0 != 0x80 { n += 1 }
        if b >= 0xF0 { n += 1 }
    }
    return n
}

private func byteCount(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .binary) }

private func count(_ n: Int) -> String { n.formatted(.number) }

/// Each version of a file's admission, by its blob ID, so every part of the app that takes the
/// version in decides the same, and a version too large to show is read once.
public final class Admissions: Sendable {
    private struct State {
        var byID: [String: Admission] = [:]
        var order = UseOrder<String>()
    }

    private let state = Mutex(State())
    private let capacity: Int

    /// The admissions the app shares.
    public static let shared = Admissions()

    /// - Parameter capacity: The most versions remembered; the least recently used go first.
    public init(capacity: Int = 100_000) {
        self.capacity = capacity
    }

    /// The admission of the version with a blob ID, if it's been decided.
    public subscript(oid: String) -> Admission? {
        state.withLock { s in
            guard let a = s.byID[oid] else { return nil }
            s.order.touch(oid)
            return a
        }
    }

    /// Remembers a version's admission.
    public func record(_ admission: Admission, for oid: String) {
        guard oid != zeroOid else { return }
        state.withLock { s in
            s.byID[oid] = admission
            s.order.use(oid, cost: 1)
            while s.order.count > capacity, let oldest = s.order.removeOldest() { s.byID[oldest] = nil }
        }
    }

    /// Measures contents, and remembers their admission under their blob ID.
    @discardableResult
    public func measure(_ data: Data, oid: String) -> Admission {
        let a = Admission(measuring: data)
        record(a, for: oid)
        return a
    }
}

/// A file's lines as Sextant takes them in: split as `splitLines(_:)` splits them, with each line
/// cut to `ContentLimits.lineWidth`.
public struct AdmittedLines: Sendable, Hashable {
    public var lines: [String]
    /// How many UTF-16 units were left out at the end of each line that was cut, by line index.
    public var cut: [Int: Int]

    public init(lines: [String], cut: [Int: Int] = [:]) {
        self.lines = lines
        self.cut = cut
    }

    /// Splits contents into lines, keeping at most some of them, each cut to the line width.
    ///
    /// - Parameters:
    ///   - limit: The most lines kept.
    ///   - complete: Whether the data is all of the contents, rather than their start, whose
    ///     last line is left out unless it ends there or is the only one.
    public init(_ data: Data, limit: Int = .max, complete: Bool = true) {
        var lines: [String] = []
        var cut: [Int: Int] = [:]
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let count = raw.count
            var start = 0
            while start < count, lines.count < limit {
                let found = memchr(base + start, 0x0A, count - start)
                if found == nil, !complete, !lines.isEmpty { break }
                let end = found.map { base.distance(to: UnsafeRawPointer($0)) } ?? count
                var length = end - start
                if length > 0, raw[end - 1] == 0x0D { length -= 1 }
                let (text, left) = admittedLine(UnsafeRawBufferPointer(rebasing: raw[start..<start + length]))
                if left > 0 { cut[lines.count] = left }
                lines.append(text)
                start = end + 1
            }
        }
        self.init(lines: lines, cut: cut)
    }
}

/// Decodes a line's UTF-8 bytes, cut to the line width, decoding only the part kept.
///
/// - Returns: The text, and how many UTF-16 units were left out after it.
func admittedLine(_ bytes: UnsafeRawBufferPointer) -> (text: String, left: Int) {
    guard bytes.count > ContentLimits.lineWidth else { return (String(decoding: bytes, as: UTF8.self), 0) }
    var end = min(bytes.count, ContentLimits.lineWidth * 4)
    while end < bytes.count, end > 0, bytes[end] & 0xC0 == 0x80 { end -= 1 }
    let (text, left) = cutLine(String(decoding: UnsafeRawBufferPointer(rebasing: bytes[..<end]), as: UTF8.self))
    let rest = utf16Count(UnsafeRawBufferPointer(rebasing: bytes[end...]))
    return (text, left + rest)
}

/// Cuts a line to the line width, without splitting a character's surrogate pair.
///
/// - Returns: The text kept, and how many UTF-16 units were left out after it.
public func cutLine(_ text: String) -> (text: String, left: Int) {
    let units = text.utf16
    let width = units.count
    guard width > ContentLimits.lineWidth else { return (text, 0) }
    var keep = ContentLimits.lineWidth
    if UTF16.isLeadSurrogate(units[units.index(units.startIndex, offsetBy: keep - 1)]) { keep -= 1 }
    return (String(decoding: units.prefix(keep), as: UTF16.self), width - keep)
}

/// Bounds how much text is analyzed at once, so analyses running together, each within the
/// analysis limit, can't fill memory between them.
///
/// Each analysis holds as many bytes of the budget as its text has while it runs, in the order
/// they ask. A text larger than the whole budget runs once nothing else does.
public final class AnalysisGate: Sendable {
    private struct Waiter {
        var id: Int
        var bytes: Int
        var continuation: CheckedContinuation<Bool, Never>
    }

    private struct State {
        var inFlight = 0
        var running = 0
        var waiting: [Waiter] = []
        var lastID = 0
    }

    private let state = Mutex(State())
    private let budget: Int

    /// The gate every analysis in the app goes through.
    public static let shared = AnalysisGate(budget: ContentLimits.analysisInFlight)

    /// - Parameter budget: The most bytes analyzed at once.
    public init(budget: Int) {
        self.budget = budget
    }

    /// How many analyses hold the gate now.
    public var running: Int { state.withLock { $0.running } }

    /// Runs some analysis once its text fits beside the others running.
    ///
    /// - Parameter bytes: The size of the text it analyzes.
    /// - Returns: What the analysis returns, or nil if the task was cancelled while it waited.
    public func run<T>(bytes: Int, _ analysis: () async throws -> T) async rethrows -> T? {
        guard await enter(bytes) else { return nil }
        defer { leave(bytes) }
        return try await analysis()
    }

    private func fits(_ bytes: Int, _ s: State) -> Bool { s.running == 0 || s.inFlight + bytes <= budget }

    private func enter(_ bytes: Int) async -> Bool {
        let id = state.withLock { s in
            s.lastID += 1
            return s.lastID
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                let admitted = state.withLock { s -> Bool? in
                    guard !Task.isCancelled else { return false }
                    guard s.waiting.isEmpty, fits(bytes, s) else {
                        s.waiting.append(Waiter(id: id, bytes: bytes, continuation: c))
                        return nil
                    }
                    s.inFlight += bytes
                    s.running += 1
                    return true
                }
                if let admitted { c.resume(returning: admitted) }
            }
        } onCancel: {
            let waiter = state.withLock { s -> Waiter? in
                guard let i = s.waiting.firstIndex(where: { $0.id == id }) else { return nil }
                return s.waiting.remove(at: i)
            }
            waiter?.continuation.resume(returning: false)
        }
    }

    private func leave(_ bytes: Int) {
        let admitted = state.withLock { s -> [CheckedContinuation<Bool, Never>] in
            s.inFlight -= bytes
            s.running -= 1
            var out: [CheckedContinuation<Bool, Never>] = []
            while let first = s.waiting.first, fits(first.bytes, s) {
                s.waiting.removeFirst()
                s.inFlight += first.bytes
                s.running += 1
                out.append(first.continuation)
            }
            return out
        }
        for c in admitted { c.resume(returning: true) }
    }
}
