import CryptoKit
import Foundation
import SwiftTreeSitter

public enum TokenKind: Sendable, Hashable {
    case keyword, string, comment, number, type, function, constant, attribute, variable, tag, property

    /// Creates the colour role for a highlight capture name, such as "function.method".
    init?(capture name: String) {
        let parts = name.split(separator: ".")
        switch parts.first {
        case "keyword", "conditional", "repeat", "include", "exception", "storageclass": self = .keyword
        case "string", "character", "escape": self = .string
        case "comment": self = .comment
        case "number", "float", "boolean": self = .number
        case "type", "constructor", "module", "namespace": self = .type
        case "function", "method": self = .function
        case "constant": self = parts.dropFirst().first == "builtin" ? .keyword : .constant
        case "attribute", "label", "annotation", "decorator": self = .attribute
        case "variable":
            switch parts.dropFirst().first {
            case "builtin": self = .keyword
            case "parameter": self = .variable
            case "member": self = .property
            default: return nil
            }
        case "tag": self = .tag
        case "property", "field": self = .property
        case "embedded", "punctuation", "operator", "text", "none": return nil
        default: return nil
        }
    }
}

public struct Token: Sendable, Hashable {
    /// The UTF-16 range in the text that was highlighted.
    public var range: NSRange
    public var kind: TokenKind
}

/// A definition or reference found by a grammar's tags query.
public struct Symbol: Sendable, Hashable {
    public var name: String
    /// The kind from the capture name, such as "function", "method", "class" or "call".
    public var kind: String
    public var isDefinition: Bool
    /// The UTF-16 range of the whole definition or reference.
    public var range: NSRange
    public var nameRange: NSRange
    /// The zero-based line of the name, where "go to definition" lands.
    public var nameLine: Int
    /// The zero-based lines spanned by `range`.
    public var lines: ClosedRange<Int>
}

public final class SyntaxLanguage: Sendable {
    public let name: String
    /// Names this build of the grammar and its queries, so what parsing found with another build
    /// isn't taken for what this one would find.
    public let version: String
    let language: SwiftTreeSitter.Language
    let highlightsQuery: CheckedQuery?
    let tagsQuery: CheckedQuery?
    let localsQuery: CheckedQuery?

    /// The grammar's keyword nodes: named node types that only ever match fixed text, such as
    /// C++'s `auto`, unlike an identifier, which matches a pattern.
    let keywordNodes: Set<String>

    init(name: String, version: String, language: SwiftTreeSitter.Language, highlights: Query?, tags: Query?, locals: Query?,
         keywordNodes: Set<String>) {
        self.keywordNodes = keywordNodes
        self.name = name
        self.version = version
        self.language = language
        highlightsQuery = highlights.map(CheckedQuery.init)
        tagsQuery = tags.map(CheckedQuery.init)
        localsQuery = locals.map(CheckedQuery.init)
    }

    public var hasTags: Bool { tagsQuery != nil }

    /// Parses a text, stopping once the budget says to.
    ///
    /// The parser reads the text a chunk at a time, and each read checks the budget: a read
    /// that finds it spent ends the text there, so the parse finishes at once and is thrown away.
    /// The parser's own timeout stops it between reads.
    ///
    /// - Returns: The tree, or nil if the grammar won't load.
    /// - Throws: `AnalysisStop` when the budget ran out first.
    func parse(_ text: String, budget: AnalysisBudget) throws(AnalysisStop) -> MutableTree? {
        let parser = Parser()
        guard (try? parser.setLanguage(language)) != nil else { return nil }
        parser.timeout = max(0.001, budget.secondsLeft)
        var stopped: AnalysisStop?
        let units = Array(text.utf16)
        let tree = units.withUnsafeBytes { bytes in
            parser.parse(tree: nil as Tree?) { offset, _ in
                if let stop = budget.spent() {
                    stopped = stop
                    return nil
                }
                guard offset < bytes.count else { return nil }
                return Data(bytes[offset..<min(bytes.count, offset + Self.readChunk)])
            }
        }
        if let stopped { throw stopped }
        guard let tree else { throw budget.spent() ?? .tooSlow }
        return tree
    }

    /// The most bytes the parser reads at once, so it checks its budget at least this often.
    private static let readChunk = 1 << 16

    /// Returns the syntax tokens for the whole text, or none if analyzing it runs out of budget.
    ///
    /// Later tokens are more specific and win where they overlap.
    public func tokens(_ text: String) -> [Token] { (try? analyze(text, symbols: false))?.tokens ?? [] }

    /// Returns the definitions and references in the text, in document order.
    ///
    /// A name that several query patterns match, like a Swift method that is also a function, is
    /// kept once, as the first pattern that matched it.
    ///
    /// - Throws: `AnalysisStop` when the budget runs out first.
    public func symbols(_ text: String, budget: AnalysisBudget = AnalysisBudget()) throws(AnalysisStop) -> [Symbol] {
        try autoreleasepool { () throws(AnalysisStop) -> [Symbol] in
            guard let tree = try parse(text, budget: budget) else { return [] }
            return try symbols(in: tree, text, budget: budget)
        }
    }

    /// Returns the tokens and, if asked, the symbols of a text, parsing it once.
    ///
    /// Runs in its own autorelease pool, since the text it bridges is as big as the file and
    /// background tasks never drain one.
    ///
    /// - Throws: `AnalysisStop` when the budget runs out first.
    public func analyze(_ text: String, symbols wanted: Bool, budget: AnalysisBudget = AnalysisBudget()) throws(AnalysisStop) -> (tokens: [Token], symbols: [Symbol]) {
        try autoreleasepool { () throws(AnalysisStop) -> (tokens: [Token], symbols: [Symbol]) in
            guard let tree = try parse(text, budget: budget) else { return ([], []) }
            return (try tokens(in: tree, text, budget: budget), wanted ? try symbols(in: tree, text, budget: budget) : [])
        }
    }

    private func tokens(in tree: MutableTree, _ text: String, budget: AnalysisBudget) throws(AnalysisStop) -> [Token] {
        guard let q = highlightsQuery else { return [] }
        let run = q.run(in: tree, text, budget: budget)
        let found = run.highlights()
        if let stop = run.stop { throw stop }
        return found.compactMap { r in TokenKind(capture: r.name).map { Token(range: r.range, kind: $0) } }
    }

    private func symbols(in tree: MutableTree, _ text: String, budget: AnalysisBudget) throws(AnalysisStop) -> [Symbol] {
        guard let q = tagsQuery else { return [] }
        let ns = text as NSString
        let lines = LineIndex(text)
        var out: [Symbol] = []
        let run = q.run(in: tree, text, budget: budget)
        for match in run {
            guard let nameCapture = match.captures(named: "name").first else { continue }
            for c in match.captures {
                guard let capture = c.name, capture.hasPrefix("definition.") || capture.hasPrefix("reference.") else { continue }
                let isDef = capture.hasPrefix("definition.")
                let range = isDef ? SyntaxLanguage.declaration(around: nameCapture.node, within: c.node).range : c.node.range
                out.append(Symbol(
                    name: ns.substring(with: nameCapture.node.range),
                    kind: String(capture.drop { $0 != "." }.dropFirst()),
                    isDefinition: isDef,
                    range: range,
                    nameRange: nameCapture.node.range,
                    nameLine: lines.line(at: nameCapture.node.range.location),
                    lines: lines.line(at: range.location)...lines.line(at: max(range.location, NSMaxRange(range) - 1))
                ))
            }
        }
        if let stop = run.stop { throw stop }
        var seen = Set<String>()
        let unique = out.filter { seen.insert("\($0.isDefinition) \($0.nameRange.location) \($0.nameRange.length)").inserted }
        return unique.sorted { $0.range.location < $1.range.location }
    }

    /// Returns the declaration a definition's name belongs to.
    ///
    /// Some tags queries capture a member's definition as the whole type around it, so the
    /// nearest declaration above the name inside the capture is the definition's own. A
    /// declaration right inside the capture is the capture's own header instead, like the
    /// signature of a Vim function or the variable of a Kotlin property.
    static func declaration(around name: Node, within capture: Node) -> Node {
        var n = name.parent
        while let node = n, node.range != capture.range {
            if let type = node.nodeType, type.hasSuffix("declaration") || type.hasSuffix("definition"),
               node.parent?.range != capture.range { return node }
            n = node.parent
        }
        return capture
    }
}

/// Maps UTF-16 offsets to zero-based line numbers.
struct LineIndex {
    private var starts: [Int] = [0]
    init(_ text: String) {
        var i = 0
        for u in text.utf16 {
            i += 1
            if u == 0x0A { starts.append(i) }
        }
    }
    func line(at offset: Int) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}

/// The grammars available to Sextant, loaded lazily by file name.
public final class SyntaxRuntime: @unchecked Sendable {
    private struct Entry: Decodable {
        var name: String
        var symbol: String
        var fileTypes: [String]
        /// The grammar's keyword node types, or nil if the runtime couldn't list them.
        var keywordNodes: [String]?
    }

    public let directory: URL
    private let byFileType: [String: Entry]
    private let lock = NSLock()
    private var slots: [String: Slot] = [:]

    /// One grammar, loaded once, with its own lock so different grammars load in parallel.
    private final class Slot: @unchecked Sendable {
        private let lock = NSLock()
        private var language: SyntaxLanguage??

        func get(_ load: () -> SyntaxLanguage?) -> SyntaxLanguage? {
            lock.lock()
            defer { lock.unlock() }
            if let l = language { return l }
            let l = load()
            language = .some(l)
            return l
        }
    }

    public init?(directory: URL) {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("languages.json")),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return nil }
        self.directory = directory
        var map: [String: Entry] = [:]
        for e in entries {
            for t in e.fileTypes where map[t] == nil { map[t] = e }
        }
        byFileType = map
    }

    /// The runtime at `$SEXTANT_SYNTAX` (set by the dev shell), else the copy inside the app bundle.
    public static let shared: SyntaxRuntime? = {
        if let env = ProcessInfo.processInfo.environment["SEXTANT_SYNTAX"], let r = SyntaxRuntime(directory: URL(fileURLWithPath: env)) { return r }
        if let res = Bundle.main.resourceURL, let r = SyntaxRuntime(directory: res.appendingPathComponent("syntax")) { return r }
        return nil
    }()

    /// Returns the grammar for a path, by whole file name ("Makefile", "go.mod"), else by extension.
    public func language(forPath path: String) -> SyntaxLanguage? {
        guard let e = entry(forPath: path) else { return nil }
        return slot(e.name).get { load(e) }
    }

    /// Whether there's a grammar for a path, without loading it.
    public func hasLanguage(forPath path: String) -> Bool { entry(forPath: path) != nil }

    /// Loads the grammars some paths need, in parallel, so the first files to show don't wait
    /// for them one by one.
    public func preload(paths: [String]) async {
        var seen = Set<String>()
        let needed = paths.compactMap { p in entry(forPath: p).flatMap { seen.insert($0.name).inserted ? p : nil } }
        await withTaskGroup(of: Void.self) { group in
            for p in needed { group.addTask { _ = self.language(forPath: p) } }
        }
    }

    private func entry(forPath path: String) -> Entry? {
        let file = (path as NSString).lastPathComponent
        let ext = (file as NSString).pathExtension
        return byFileType[file] ?? byFileType[ext] ?? byFileType[ext.lowercased()]
    }

    private func slot(_ name: String) -> Slot {
        lock.lock()
        defer { lock.unlock() }
        if let s = slots[name] { return s }
        let s = Slot()
        slots[name] = s
        return s
    }

    private func load(_ e: Entry) -> SyntaxLanguage? {
        let dir = directory.appendingPathComponent(e.name)
        guard let handle = dlopen(dir.appendingPathComponent("parser").path, RTLD_NOW | RTLD_LOCAL),
              let sym = dlsym(handle, e.symbol) else { return nil }
        typealias Entrypoint = @convention(c) () -> OpaquePointer
        let language = SwiftTreeSitter.Language(language: unsafeBitCast(sym, to: Entrypoint.self)())
        var digest = SHA256()
        func read(_ file: String) -> Data? {
            let data = try? Data(contentsOf: dir.appendingPathComponent(file))
            digest.update(data: Data(file.utf8))
            digest.update(data: data ?? Data())
            return data
        }
        _ = read("parser")
        func query(_ file: String) -> Query? {
            guard let data = read(file) else { return nil }
            return try? Query(language: language, data: data)
        }
        let highlights = query("highlights.scm"), tags = query("tags.scm"), locals = query("locals.scm")
        let version = e.name + "@" + digest.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
        return SyntaxLanguage(name: e.name, version: version, language: language, highlights: highlights, tags: tags, locals: locals,
                              keywordNodes: Set(e.keywordNodes ?? []))
    }
}

/// Splits tokens found in `lines.joined(separator: "\n")` into per-line tokens.
///
/// The returned ranges are relative to each line. A token spanning lines, such as a block
/// comment, is cut at each line break.
public func tokensPerLine(_ tokens: [Token], lines: [String]) -> [[Token]] {
    var starts: [Int] = []
    starts.reserveCapacity(lines.count)
    var offset = 0
    for l in lines {
        starts.append(offset)
        offset += l.utf16.count + 1
    }
    var out = [[Token]](repeating: [], count: lines.count)
    guard !lines.isEmpty else { return out }
    var line = 0
    for t in tokens.sorted(by: { $0.range.location < $1.range.location }) {
        while line > 0, starts[line] > t.range.location { line -= 1 }
        while line + 1 < starts.count, starts[line + 1] <= t.range.location { line += 1 }
        var l = line
        var start = t.range.location
        let end = NSMaxRange(t.range)
        while l < lines.count, start < end {
            let lineEnd = starts[l] + lines[l].utf16.count
            let e = min(end, lineEnd)
            if e > start { out[l].append(Token(range: NSRange(location: start - starts[l], length: e - start), kind: t.kind)) }
            l += 1
            if l < lines.count { start = starts[l] }
        }
    }
    return out
}
