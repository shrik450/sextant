import Foundation
import SwiftTreeSitter

/// Why analyzing a text stopped before it finished.
public enum AnalysisStop: Error, Sendable, Equatable {
    /// Its task was cancelled: nothing wants it any more.
    case cancelled
    /// It ran past `ContentLimits.analysisTime`.
    case tooSlow
    /// A query captured more than `ContentLimits.capturesPerQuery`.
    case tooManyCaptures

    /// Why the analysis was abandoned, in words for the reader; nil for a cancelled one, which
    /// nobody sees.
    public var reason: String? {
        switch self {
        case .cancelled: nil
        case .tooSlow: "analyzing it took longer than \(Int(ContentLimits.analysisTime.components.seconds)) seconds"
        case .tooManyCaptures: "it holds more than \(ContentLimits.capturesPerQuery.formatted(.number)) pieces of syntax"
        }
    }
}

/// How long analyzing a text may go on, and whether anything still wants it.
public struct AnalysisBudget: Sendable {
    private let deadline: ContinuousClock.Instant
    /// The most captures one query run takes.
    let captures: Int

    /// - Parameters:
    ///   - time: How long the analysis may take, from now.
    ///   - captures: The most captures one query run takes.
    public init(time: Duration = ContentLimits.analysisTime, captures: Int = ContentLimits.capturesPerQuery) {
        deadline = .now + time
        self.captures = captures
    }

    /// Why the analysis must stop now, if it must: the task running it was cancelled, or it ran
    /// past its time.
    func spent() -> AnalysisStop? {
        if Task.isCancelled { return .cancelled }
        if ContinuousClock.now > deadline { return .tooSlow }
        return nil
    }

    /// The seconds left before the deadline.
    var secondsLeft: Double {
        let left = (deadline - .now).components
        return Double(left.seconds) + Double(left.attoseconds) * 1e-18
    }
}

/// One run of a query over a tree, which ends early once its budget is spent or it has
/// captured too much, and says why.
final class QueryRun: Sequence, IteratorProtocol {
    private let matches: AnyIterator<QueryMatch>
    private let budget: AnalysisBudget
    private var captured = 0
    private var taken = 0
    /// Why the run ended early, once it has.
    private(set) var stop: AnalysisStop?

    /// How many matches go by between checks of the budget, which reads the clock.
    private static let checkEvery = 64

    init(_ matches: AnyIterator<QueryMatch>, budget: AnalysisBudget) {
        self.matches = matches
        self.budget = budget
    }

    func next() -> QueryMatch? {
        guard stop == nil else { return nil }
        taken += 1
        if taken % Self.checkEvery == 0, let spent = budget.spent() {
            stop = spent
            return nil
        }
        guard let match = matches.next() else { return nil }
        captured += match.captures.count
        if captured > budget.captures {
            stop = .tooManyCaptures
            return nil
        }
        return match
    }
}

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

    /// Runs the query over a tree, for the matches that pass every predicate, within a budget.
    func run(in tree: MutableTree, _ text: String, budget: AnalysisBudget) -> QueryRun {
        let ns = text as NSString
        let matches = query.execute(in: tree).resolve(with: .init(string: text)).lazy.filter { allows($0, ns) }
        return QueryRun(AnyIterator(matches.makeIterator()), budget: budget)
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
