import Foundation

/// A definition in a changed file's outline, with how the change touched it.
public struct OutlineItem: Sendable, Equatable {
    public enum Change: Sendable, Equatable {
        case none
        /// Changed lines fall inside it, on either side.
        case modified
        /// It's new: the old side has no definition of that kind and name inside the same
        /// definitions.
        case added
        /// It's gone: only the old side defines it.
        case deleted
    }

    public var name: String
    public var kind: String
    public var change: Change
    /// The zero-based line of its name, on the old side when deleted and the new side otherwise.
    public var line: Int
    /// The new-side lines it spans, or the place it was for a deleted definition.
    public var span: ClosedRange<Int>
    public var children: [OutlineItem]
    /// Whether changed lines fall inside it outside every definition inside it, on either side.
    public var ownsChange: Bool

    public init(name: String, kind: String, change: Change, line: Int, span: ClosedRange<Int>, children: [OutlineItem], ownsChange: Bool) {
        self.name = name
        self.kind = kind
        self.change = change
        self.line = line
        self.span = span
        self.children = children
        self.ownsChange = ownsChange
    }

    /// Whether this item or any item inside it was touched by the change.
    public var isTouched: Bool { change != .none || children.contains(where: \.isTouched) }
}

/// Returns the definitions that belong in a file's outline, leaving out those inside functions
/// and methods, such as their local variables.
///
/// - Parameter definitions: Definitions sorted by where they start.
public func outlineDefinitions(_ definitions: [Symbol]) -> [Symbol] {
    zip(definitions, inOutline(definitions)).filter(\.1).map(\.0)
}

/// Returns whether each definition belongs in a file's outline, rather than inside a function or
/// method, like a local variable.
///
/// - Parameter definitions: Definitions sorted by where they start.
public func inOutline(_ definitions: [Symbol]) -> [Bool] {
    var functionEnd = -1
    return definitions.map { d in
        guard d.range.location >= functionEnd else { return false }
        if d.kind == "function" || d.kind == "method" { functionEnd = NSMaxRange(d.range) }
        return true
    }
}

/// Builds a file's outline from the definitions on each side of its diff.
///
/// A definition on one side is the same as one on the other when they have the same kind and
/// name inside definitions that are the same, so same-named methods of different types stay
/// apart. Definitions nest by the lines they span. A definition only the old side has is placed
/// where its lines were removed, inside what held it on the old side.
///
/// - Parameters:
///   - lines: The file's lines, whole.
///   - new: The new side's definitions.
///   - old: The old side's definitions.
public func outline(lines: [DiffLine], new: [Symbol], old: [Symbol]) -> [OutlineItem] {
    let newSide = OutlineSide(new), oldSide = OutlineSide(old)
    var oldByKey: [String: [Int]] = [:]
    for i in oldSide.order.reversed() { oldByKey[oldSide.keys[i], default: []].append(i) }
    var match = [Int?](repeating: nil, count: new.count)
    var matched = Set<Int>()
    for i in newSide.order {
        guard let o = oldByKey[newSide.keys[i]]?.popLast() else { continue }
        match[i] = o
        matched.insert(o)
    }
    let addedLines = Set(lines.lazy.filter { $0.kind == .added }.map { $0.newNo - 1 })
    let removedLines = Set(lines.lazy.filter { $0.kind == .deleted }.map { $0.oldNo - 1 })
    func touched(_ s: Symbol, side: OutlineSide, _ i: Int, _ changed: Set<Int>) -> (any: Bool, own: Bool) {
        var any = false
        for l in s.lines where changed.contains(l) {
            any = true
            if !side.children[i].contains(where: { side.symbols[$0].lines.contains(l) }) { return (true, true) }
        }
        return (any, false)
    }

    var items: [OutlineItem] = []
    var children: [[Int]] = []
    var roots: [Int] = []
    var itemOfNew = [Int](repeating: -1, count: new.count)
    var itemOfOld = [Int](repeating: -1, count: old.count)
    func add(_ item: OutlineItem, under parent: Int?) -> Int {
        items.append(item)
        children.append([])
        if let parent { children[parent].append(items.count - 1) } else { roots.append(items.count - 1) }
        return items.count - 1
    }
    for i in newSide.order {
        let s = new[i]
        var change = OutlineItem.Change.added, owns = true
        if let o = match[i] {
            let a = touched(s, side: newSide, i, addedLines), r = touched(old[o], side: oldSide, o, removedLines)
            change = a.any || r.any ? .modified : .none
            owns = a.own || r.own
        }
        let item = OutlineItem(name: s.name, kind: s.kind, change: change, line: s.nameLine, span: s.lines, children: [], ownsChange: owns)
        itemOfNew[i] = add(item, under: newSide.parents[i].map { itemOfNew[$0] })
        if let o = match[i] { itemOfOld[o] = itemOfNew[i] }
    }
    let newLineOfOld = newPositions(lines)
    for o in oldSide.order where !matched.contains(o) {
        let s = old[o], at = newLineOfOld(s.lines.lowerBound)
        let item = OutlineItem(name: s.name, kind: s.kind, change: .deleted, line: s.nameLine, span: at...at, children: [], ownsChange: true)
        itemOfOld[o] = add(item, under: oldSide.parents[o].map { itemOfOld[$0] })
    }

    func build(_ ids: [Int]) -> [OutlineItem] {
        let ordered = ids.enumerated().sorted { x, y in
            let a = items[x.element], b = items[y.element]
            if a.span.lowerBound != b.span.lowerBound { return a.span.lowerBound < b.span.lowerBound }
            if (a.change == .deleted) != (b.change == .deleted) { return b.change == .deleted }
            if a.span.upperBound != b.span.upperBound { return a.span.upperBound > b.span.upperBound }
            return x.offset < y.offset
        }
        return ordered.map { _, id in
            var item = items[id]
            item.children = build(children[id])
            return item
        }
    }
    return build(roots)
}

/// One side's definitions, with what holds each and the key it's matched by.
private struct OutlineSide {
    let symbols: [Symbol]
    /// The indices of the symbols in outline order: by where they start, outer ones first.
    let order: [Int]
    /// The symbol holding each one, if any.
    let parents: [Int?]
    let children: [[Int]]
    /// Each symbol's kind and name, after those of the symbols holding it.
    let keys: [String]

    init(_ symbols: [Symbol]) {
        self.symbols = symbols
        order = symbols.indices.sorted { a, b in
            let x = symbols[a].lines, y = symbols[b].lines
            if x.lowerBound != y.lowerBound { return x.lowerBound < y.lowerBound }
            if x.upperBound != y.upperBound { return x.upperBound > y.upperBound }
            return a < b
        }
        var parents = [Int?](repeating: nil, count: symbols.count)
        var children = [[Int]](repeating: [], count: symbols.count)
        var keys = [String](repeating: "", count: symbols.count)
        var open: [Int] = []
        for i in order {
            let s = symbols[i].lines
            while let top = open.last {
                let t = symbols[top].lines
                if t != s, t.lowerBound <= s.lowerBound, s.upperBound <= t.upperBound { break }
                open.removeLast()
            }
            parents[i] = open.last
            if let p = open.last { children[p].append(i) }
            keys[i] = (open.last.map { keys[$0] + "\n" } ?? "") + symbols[i].kind + " " + symbols[i].name
            open.append(i)
        }
        self.parents = parents
        self.children = children
        self.keys = keys
    }
}

/// Returns the definitions a change touched directly, in the order the outline lists them.
///
/// Added and deleted definitions count, and so do modified ones with changed lines of their
/// own. A definition marked modified only because a definition inside it changed doesn't.
public func changedDefinitions(in outline: [OutlineItem]) -> [OutlineItem] {
    outline.flatMap { item -> [OutlineItem] in
        let owns = item.change == .added || item.change == .deleted || (item.change == .modified && item.ownsChange)
        return (owns ? [item] : []) + changedDefinitions(in: item.children)
    }
}

/// Returns a function mapping a zero-based old-side line to the zero-based new-side line that
/// now stands where it was.
private func newPositions(_ lines: [DiffLine]) -> (Int) -> Int {
    var map: [Int: Int] = [:]
    var following = lines.last { $0.kind != .deleted }?.newNo ?? 0
    for l in lines.reversed() {
        if l.kind != .deleted { following = l.newNo - 1 }
        if l.kind != .added { map[l.oldNo - 1] = following }
    }
    return { map[$0] ?? 0 }
}
