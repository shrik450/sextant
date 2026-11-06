import Foundation
import SwiftTreeSitter

/// What a grammar's locals query found in a text, as UTF-16 ranges into it.
///
/// Sextant reads the captures tree-sitter defines for locals, and one of its own:
///
/// - `@local.scope` marks a node whose definitions only its own text sees. A scope set with
///   `(#set! local.scope-inherits false)` doesn't see the definitions of the scopes around it.
/// - `@local.definition`, or any capture under it such as `@local.definition.var`, marks a name
///   that defines something in the innermost scope around it. `(#set! local.definition-scope …)`
///   places it elsewhere: `"parent"` in the scope around that one, as a nested function's name
///   belongs to the scope it's declared in rather than its own body, and `"nearest"` in the
///   nearest scope around it that defines the name already, as an assignment in a Ruby block
///   assigns to a variable of the method around it, else in the innermost scope.
/// - `@local.reference` marks a name that refers to a definition in the scopes around it.
/// - `@nonlocal` marks a name that never refers to a local, such as a member read through a
///   value, even where `@local.reference` captures it too.
struct LocalCaptures: Sendable {
    struct Scope: Sendable {
        var range: NSRange
        var inherits = true
    }

    /// Which scope a definition defines its name in.
    enum Placement: Sendable {
        case innermost
        case parent
        case nearest
    }

    struct Definition: Sendable {
        var range: NSRange
        var placement = Placement.innermost
    }

    var scopes: [Scope] = []
    var definitions: [Definition] = []
    var references: [NSRange] = []
    var nonlocal: [NSRange] = []
}

/// Groups names that name the same thing, giving each name the ID of what it names.
///
/// A name the locals define in a scope shares a local ID with the names in that scope, and in
/// the scopes inside it, that refer to it, wherever they are in the scope: a comprehension uses
/// its variable before defining it, and a function can call a function declared after it. Every
/// other name, such as a type, a member or anything defined outside every scope, shares an ID
/// with the other such names spelled the same way, since without a scope the spelling is all
/// there is to go by.
///
/// - Parameters:
///   - names: The names' ranges in the text, in order, each with its spelling.
///   - locals: What the grammar's locals query found, or nil if it has none.
/// - Returns: Each name's ID, and how many of the IDs are local. Local IDs come first.
func resolveNames(_ names: [(range: NSRange, spelling: String)], locals: LocalCaptures?) -> (ids: [Int], locals: Int) {
    var scopes: [LocalCaptures.Scope] = []
    for s in (locals?.scopes ?? []).sorted(by: { $0.range.location != $1.range.location ? $0.range.location < $1.range.location : $0.range.length > $1.range.length }) {
        if let last = scopes.last, last.range == s.range {
            scopes[scopes.count - 1].inherits = last.inherits && s.inherits
        } else {
            scopes.append(s)
        }
    }
    var parent = [Int](repeating: -1, count: scopes.count)
    var open: [Int] = []
    for (i, s) in scopes.enumerated() {
        while let top = open.last, NSMaxRange(scopes[top].range) < NSMaxRange(s.range) { open.removeLast() }
        parent[i] = open.last ?? -1
        open.append(i)
    }

    enum Role {
        case definition(LocalCaptures.Placement)
        case reference
        case nonlocal
    }
    var roles: [Int: (length: Int, role: Role)] = [:]
    for r in locals?.references ?? [] { roles[r.location] = (r.length, .reference) }
    for d in locals?.definitions ?? [] { roles[d.range.location] = (d.range.length, .definition(d.placement)) }
    for r in locals?.nonlocal ?? [] { roles[r.location] = (r.length, .nonlocal) }
    func role(of n: (range: NSRange, spelling: String)) -> Role? {
        guard let found = roles[n.range.location], found.length == n.range.length else { return nil }
        return found.role
    }

    struct LocalKey: Hashable {
        var scope: Int
        var spelling: String
    }
    var defined: [LocalKey: Int] = [:]
    var ids = [Int?](repeating: nil, count: names.count)
    func define(_ i: Int, in scope: Int) {
        guard scope >= 0 else { return }
        let key = LocalKey(scope: scope, spelling: names[i].spelling)
        let id = defined[key] ?? defined.count
        defined[key] = id
        ids[i] = id
    }
    func lookUp(_ spelling: String, from innermost: Int) -> Int? {
        var scope = innermost
        while scope >= 0 {
            if let id = defined[LocalKey(scope: scope, spelling: spelling)] { return id }
            scope = scopes[scope].inherits ? parent[scope] : -1
        }
        return nil
    }

    var innermost = [Int](repeating: -1, count: names.count)
    var next = 0
    open = []
    for (i, n) in names.enumerated() {
        let at = n.range.location
        while let top = open.last, NSMaxRange(scopes[top].range) <= at { open.removeLast() }
        while next < scopes.count, scopes[next].range.location <= at {
            if NSMaxRange(scopes[next].range) > at { open.append(next) }
            next += 1
        }
        innermost[i] = open.last ?? -1
        switch role(of: n) {
        case .definition(.innermost): define(i, in: innermost[i])
        case .definition(.parent): define(i, in: innermost[i] >= 0 ? parent[innermost[i]] : -1)
        default: break
        }
    }
    for (i, n) in names.enumerated() {
        guard case .definition(.nearest) = role(of: n) else { continue }
        if let id = lookUp(n.spelling, from: innermost[i]) { ids[i] = id } else { define(i, in: innermost[i]) }
    }

    var globals: [String: Int] = [:]
    var resolved: [Int] = []
    resolved.reserveCapacity(names.count)
    for (i, n) in names.enumerated() {
        var id = ids[i]
        if id == nil, case .reference = role(of: n) { id = lookUp(n.spelling, from: innermost[i]) }
        if let id {
            resolved.append(id)
        } else {
            let g = globals[n.spelling] ?? globals.count
            globals[n.spelling] = g
            resolved.append(defined.count + g)
        }
    }
    return (resolved, defined.count)
}

/// The names in the lines of a text, and which of them name the same thing.
///
/// A name is an identifier that isn't a keyword, comment, string or number, as
/// `identifiers(in:tokens:)` finds them, so the names here are the ones the caret and the word
/// steps land on.
public struct NameIndex: Sendable {
    /// A name, with the ID of what it names.
    public struct Name: Sendable, Hashable {
        /// The zero-based line the name is on.
        public var line: Int
        /// The name's UTF-16 range in its line.
        public var range: NSRange
        /// What the name names, shared with the names that name the same thing.
        public var binding: Int
    }

    private let names: [Name]
    /// The index in `names` of each line's first name, with the count of names at the end.
    private let lineStarts: [Int32]
    /// Indices into `names`, grouped by binding and in order within each.
    private let byBinding: [Int32]
    /// The index in `byBinding` where each binding's names start, with the count at the end.
    private let bindingStarts: [Int32]
    /// How many bindings are local, which come before those shared by spelling.
    private let localCount: Int
    /// The binding of each spelling shared by the names that aren't local.
    private let globals: [String: Int]

    /// A name before its binding is known.
    struct Candidate {
        /// The zero-based line the name is on.
        var line: Int
        /// The name's UTF-16 range in its line.
        var range: NSRange
        /// The name's UTF-16 offset in the lines joined with line feeds.
        var offset: Int
        var spelling: String
    }

    /// Returns the names in some lines: the identifiers the tokens don't mark as keywords,
    /// comments, strings or numbers, leaving out those made only of underscores, which name
    /// nothing.
    static func candidates(in lines: [String], tokens: [[Token]]) -> [Candidate] {
        var out: [Candidate] = []
        var offset = 0
        for (l, text) in lines.enumerated() {
            let s = text as NSString
            for r in identifiers(in: text, tokens: l < tokens.count ? tokens[l] : []) {
                let spelling = s.substring(with: r)
                guard spelling.contains(where: { $0 != "_" }) else { continue }
                out.append(Candidate(line: l, range: r, offset: offset + r.location, spelling: spelling))
            }
            offset += s.length + 1
        }
        return out
    }

    /// Indexes some names.
    ///
    /// - Parameters:
    ///   - lineCount: The number of lines the names are in.
    ///   - candidates: The names, in order.
    ///   - locals: What the grammar's locals query found in the lines joined with line feeds.
    init(lineCount: Int, candidates: [Candidate], locals: LocalCaptures?) {
        let resolved = resolveNames(candidates.map { (NSRange(location: $0.offset, length: $0.range.length), $0.spelling) }, locals: locals)
        var names: [Name] = []
        names.reserveCapacity(candidates.count)
        var starts = [Int32](repeating: 0, count: lineCount + 1)
        for (i, c) in candidates.enumerated() {
            names.append(Name(line: c.line, range: c.range, binding: resolved.ids[i]))
            starts[c.line + 1] += 1
        }
        for l in 0..<lineCount { starts[l + 1] += starts[l] }
        let bindings = (resolved.ids.max() ?? -1) + 1
        var bindingStarts = [Int32](repeating: 0, count: bindings + 1)
        for id in resolved.ids { bindingStarts[id + 1] += 1 }
        for b in 0..<bindings { bindingStarts[b + 1] += bindingStarts[b] }
        var fill = bindingStarts
        var byBinding = [Int32](repeating: 0, count: names.count)
        var globals: [String: Int] = [:]
        for (i, id) in resolved.ids.enumerated() {
            byBinding[Int(fill[id])] = Int32(i)
            fill[id] += 1
            if id >= resolved.locals { globals[candidates[i].spelling] = id }
        }
        self.names = names
        lineStarts = starts
        self.byBinding = byBinding
        self.bindingStarts = bindingStarts
        localCount = resolved.locals
        self.globals = globals
    }

    private func names(onLine line: Int) -> ArraySlice<Name> {
        guard line >= 0, line + 1 < lineStarts.count else { return [] }
        return names[Int(lineStarts[line])..<Int(lineStarts[line + 1])]
    }

    /// Returns the name the caret is on: the one at a column, else the one ending there, as
    /// the caret highlights the name it's just after.
    ///
    /// - Parameters:
    ///   - line: The zero-based line.
    ///   - column: The caret's UTF-16 offset in the line.
    public func name(atLine line: Int, column: Int) -> Name? {
        let onLine = names(onLine: line)
        return onLine.first { NSLocationInRange(column, $0.range) } ?? onLine.first { NSMaxRange($0.range) == column }
    }

    /// Returns the name with exactly this range, if there is one.
    public func name(atLine line: Int, range: NSRange) -> Name? {
        names(onLine: line).first { $0.range == range }
    }

    /// Returns the names that share a binding, in order.
    public func occurrences(of binding: Int) -> [Name] {
        guard binding >= 0, binding + 1 < bindingStarts.count else { return [] }
        return byBinding[Int(bindingStarts[binding])..<Int(bindingStarts[binding + 1])].map { names[Int($0)] }
    }

    /// Whether a binding is a local the scopes found, rather than every name spelled one way.
    public func isLocal(_ binding: Int) -> Bool { binding < localCount }

    /// Returns the binding shared by the names spelled some way that aren't locals.
    public func binding(spelled spelling: String) -> Int? { globals[spelling] }
}

extension SyntaxLanguage {
    /// Whether the grammar has a locals query, so names are grouped by scope rather than only by
    /// spelling.
    public var hasLocals: Bool { localsQuery != nil }

    /// Returns the names in some lines and which of them name the same thing, parsing the lines
    /// as one text to find their scopes.
    ///
    /// A name the tree shows is a keyword the highlights missed, such as a node without a name
    /// or one whose type is its own text, like C++'s `auto`, is left out. A line's trailing CR is
    /// left out, as `analysis(of:definitions:)` leaves it out.
    ///
    /// - Parameters:
    ///   - lines: The lines.
    ///   - tokens: Each line's syntax tokens, which tell names from keywords, comments, strings
    ///     and numbers.
    public func names(of lines: [String], tokens: [[Token]]) -> NameIndex {
        let canonical = lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        var candidates = NameIndex.candidates(in: canonical, tokens: tokens)
        let locals: LocalCaptures? = autoreleasepool {
            let text = canonical.joined(separator: "\n")
            guard let tree = parse(text), let root = tree.rootNode else { return nil }
            candidates.removeAll { c in
                let bytes = UInt32(c.offset * 2)..<UInt32((c.offset + c.range.length) * 2)
                guard let node = root.descendant(in: bytes), node.range.location == c.offset, node.range.length == c.range.length else { return false }
                return !node.isNamed || node.nodeType == c.spelling
            }
            return localsQuery.map { Self.locals($0, in: tree, text) }
        }
        return NameIndex(lineCount: canonical.count, candidates: candidates, locals: locals)
    }

    /// Returns what a locals query captures in a parsed text.
    ///
    /// The tree's root isn't taken for a scope, so what's defined at the top level is
    /// named by spelling like everything outside the scopes.
    static func locals(_ query: CheckedQuery, in tree: MutableTree, _ text: String) -> LocalCaptures {
        var out = LocalCaptures()
        for match in query.matches(in: tree, text) {
            for c in match.captures {
                guard let name = c.name else { continue }
                let range = c.node.range
                if name == "local.scope" {
                    guard c.node.parent != nil else { continue }
                    out.scopes.append(.init(range: range, inherits: match.metadata["local.scope-inherits"] != "false"))
                } else if name == "local.definition" || name.hasPrefix("local.definition.") {
                    let placement: LocalCaptures.Placement = switch match.metadata["local.definition-scope"] {
                    case "parent": .parent
                    case "nearest": .nearest
                    default: .innermost
                    }
                    out.definitions.append(.init(range: range, placement: placement))
                } else if name == "local.reference" {
                    out.references.append(range)
                } else if name == "nonlocal" {
                    out.nonlocal.append(range)
                }
            }
        }
        return out
    }
}
