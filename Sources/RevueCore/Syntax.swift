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
    let language: SwiftTreeSitter.Language
    let highlightsQuery: Query?
    let tagsQuery: Query?

    init(name: String, language: SwiftTreeSitter.Language, highlights: Query?, tags: Query?) {
        self.name = name
        self.language = language
        highlightsQuery = highlights
        tagsQuery = tags
    }

    public var hasTags: Bool { tagsQuery != nil }

    private func parse(_ text: String) -> MutableTree? {
        let parser = Parser()
        guard (try? parser.setLanguage(language)) != nil else { return nil }
        return parser.parse(text)
    }

    /// Returns the syntax tokens for the whole text.
    ///
    /// Later tokens are more specific and win where they overlap.
    public func tokens(_ text: String) -> [Token] {
        guard let q = highlightsQuery, let tree = parse(text) else { return [] }
        return q.execute(in: tree).resolve(with: .init(string: text)).highlights().compactMap { r in
            TokenKind(capture: r.name).map { Token(range: r.range, kind: $0) }
        }
    }

    /// Returns the definitions and references in the text, in document order.
    public func symbols(_ text: String) -> [Symbol] {
        guard let q = tagsQuery, let tree = parse(text) else { return [] }
        let ns = text as NSString
        let lines = LineIndex(text)
        var out: [Symbol] = []
        for match in q.execute(in: tree).resolve(with: .init(string: text)) {
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
        return out.sorted { $0.range.location < $1.range.location }
    }

    /// Returns the declaration a definition's name belongs to.
    ///
    /// Some tags queries capture a member's definition as the whole type around it, so the
    /// nearest declaration above the name inside the capture is the definition's own.
    static func declaration(around name: Node, within capture: Node) -> Node {
        var n = name.parent
        while let node = n, node.range != capture.range {
            if let type = node.nodeType, type.hasSuffix("declaration") || type.hasSuffix("definition") { return node }
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

/// The grammars available to Revue, loaded lazily by file name.
public final class SyntaxRuntime: @unchecked Sendable {
    private struct Entry: Decodable {
        var name: String
        var symbol: String
        var fileTypes: [String]
    }

    public let directory: URL
    private let byFileType: [String: Entry]
    private let lock = NSLock()
    private var loaded: [String: SyntaxLanguage?] = [:]

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

    /// The runtime at `$REVUE_SYNTAX` (set by the dev shell), else the copy inside the app bundle.
    public static let shared: SyntaxRuntime? = {
        if let env = ProcessInfo.processInfo.environment["REVUE_SYNTAX"], let r = SyntaxRuntime(directory: URL(fileURLWithPath: env)) { return r }
        if let res = Bundle.main.resourceURL, let r = SyntaxRuntime(directory: res.appendingPathComponent("syntax")) { return r }
        return nil
    }()

    /// Returns the grammar for a path, by whole file name ("Makefile", "go.mod"), else by extension.
    public func language(forPath path: String) -> SyntaxLanguage? {
        let file = (path as NSString).lastPathComponent
        let ext = (file as NSString).pathExtension
        guard let e = byFileType[file] ?? byFileType[ext] ?? byFileType[ext.lowercased()] else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let l = loaded[e.name] { return l }
        let l = load(e)
        loaded[e.name] = l
        return l
    }

    private func load(_ e: Entry) -> SyntaxLanguage? {
        let dir = directory.appendingPathComponent(e.name)
        guard let handle = dlopen(dir.appendingPathComponent("parser").path, RTLD_NOW | RTLD_LOCAL),
              let sym = dlsym(handle, e.symbol) else { return nil }
        typealias Entrypoint = @convention(c) () -> OpaquePointer
        let language = SwiftTreeSitter.Language(language: unsafeBitCast(sym, to: Entrypoint.self)())
        func query(_ file: String) -> Query? {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(file)) else { return nil }
            return try? Query(language: language, data: data)
        }
        return SyntaxLanguage(name: e.name, language: language, highlights: query("highlights.scm"), tags: query("tags.scm"))
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
