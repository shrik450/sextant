import Foundation
import SwiftTreeSitter

/// A query, with the predicates SwiftTreeSitter lets through unchecked checked on each match.
///
/// SwiftTreeSitter checks `#eq?` and `#match?` against strings, and passes every predicate it
/// doesn't know. This checks the ones the bundled queries use: `#eq?` and `#not-eq?` between two
/// captures, `#lua-match?` and `#not-lua-match?`, and `#has-ancestor?` and
/// `#not-has-ancestor?`. A predicate about a capture that captured nothing passes, as
/// SwiftTreeSitter's own do.
struct CheckedQuery: Sendable {
    let query: Query
    private let checks: [[Check]]

    private enum Check: Sendable {
        case capturesEqual(String, String, equal: Bool)
        case luaMatch(String, LuaPattern?, matching: Bool)
        case ancestor(String, types: Set<String>, has: Bool)
    }

    init(_ query: Query) {
        self.query = query
        checks = (0..<query.patternCount).map { i in
            query.predicates(for: i).compactMap { predicate -> Check? in
                switch predicate {
                case .eq(let strings, let names) where strings.isEmpty && names.count == 2:
                    .capturesEqual(names[0], names[1], equal: true)
                case .notEq(let strings, let names) where strings.isEmpty && names.count == 2:
                    .capturesEqual(names[0], names[1], equal: false)
                case .generic(let name, let strings, let names) where names.count == 1:
                    switch name {
                    case "lua-match?", "not-lua-match?":
                        .luaMatch(names[0], strings.count == 1 ? LuaPattern(strings[0]) : nil, matching: name == "lua-match?")
                    case "has-ancestor?", "not-has-ancestor?":
                        .ancestor(names[0], types: Set(strings), has: name == "has-ancestor?")
                    default:
                        nil
                    }
                default:
                    nil
                }
            }
        }
    }

    /// Returns the matches in a tree that pass every predicate.
    func matches(in tree: MutableTree, _ text: String) -> some Sequence<QueryMatch> {
        let ns = text as NSString
        return query.execute(in: tree).resolve(with: .init(string: text)).lazy.filter { allows($0, ns) }
    }

    private func allows(_ match: QueryMatch, _ text: NSString) -> Bool {
        guard checks.indices.contains(match.patternIndex) else { return true }
        return checks[match.patternIndex].allSatisfy { check in
            switch check {
            case .capturesEqual(let a, let b, let equal):
                let texts = Set((match.captures(named: a) + match.captures(named: b)).map { text.substring(with: $0.node.range) })
                return equal ? texts.count <= 1 : texts.count != 1
            case .luaMatch(let name, let pattern, let matching):
                let nodes = match.captures(named: name)
                guard !nodes.isEmpty else { return true }
                let all = pattern.map { p in nodes.allSatisfy { p.matches(text.substring(with: $0.node.range)) } } ?? false
                return all == matching
            case .ancestor(let name, let types, let has):
                let nodes = match.captures(named: name)
                guard !nodes.isEmpty else { return true }
                let any = nodes.contains { c in
                    var n = c.node.parent
                    while let node = n {
                        if let type = node.nodeType, types.contains(type) { return true }
                        n = node.parent
                    }
                    return false
                }
                return any == has
            }
        }
    }
}
