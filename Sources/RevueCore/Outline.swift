import Foundation

/// A definition in a changed file's outline, with how the change touched it.
public struct OutlineItem: Sendable, Equatable {
    public enum Change: Sendable, Equatable {
        case none
        /// Changed lines fall inside it.
        case modified
        /// It's new: the old side has no definition of that name and kind.
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

    /// Whether this item or any item inside it was touched by the change.
    public var isTouched: Bool { change != .none || children.contains(where: \.isTouched) }

    /// Whether `other` sits inside this definition.
    ///
    /// A deleted definition's span is the line now following where it was, so it only sits inside
    /// definitions that started before that line.
    func contains(_ other: OutlineItem) -> Bool {
        guard change != .deleted, other.span.upperBound <= span.upperBound else { return false }
        return other.change == .deleted ? span.lowerBound < other.span.lowerBound : span.lowerBound <= other.span.lowerBound
    }
}

/// Returns the definitions that belong in a file's outline, leaving out those inside functions
/// and methods, such as their local variables.
///
/// - Parameter definitions: Definitions sorted by where they start.
public func outlineDefinitions(_ definitions: [Symbol]) -> [Symbol] {
    var functionEnd = -1
    return definitions.filter { d in
        guard d.range.location >= functionEnd else { return false }
        if d.kind == "function" || d.kind == "method" { functionEnd = NSMaxRange(d.range) }
        return true
    }
}

/// Builds a file's outline from the definitions on each side of its diff.
///
/// Definitions nest by the lines they span. A definition only the old side has is placed where
/// its lines were removed.
///
/// - Parameters:
///   - lines: The file's lines, whole.
///   - new: The new side's definitions.
///   - old: The old side's definitions.
public func outline(lines: [DiffLine], new: [Symbol], old: [Symbol]) -> [OutlineItem] {
    let changedSpans: [ClosedRange<Int>] = changeRuns(lines).map { $0.newLine...($0.newLine + max(1, $0.additions) - 1) }
    let oldKeys = Set(old.map { "\($0.kind) \($0.name)" })
    let newKeys = Set(new.map { "\($0.kind) \($0.name)" })
    var items = new.map { s -> OutlineItem in
        let change: OutlineItem.Change = !oldKeys.contains("\(s.kind) \(s.name)") ? .added
            : changedSpans.contains(where: { $0.overlaps(s.lines) }) ? .modified : .none
        return OutlineItem(name: s.name, kind: s.kind, change: change, line: s.nameLine, span: s.lines, children: [])
    }
    let newLineOfOld = newPositions(lines)
    for s in old where !newKeys.contains("\(s.kind) \(s.name)") {
        let at = newLineOfOld(s.lines.lowerBound)
        items.append(OutlineItem(name: s.name, kind: s.kind, change: .deleted, line: s.nameLine, span: at...at, children: []))
    }
    items.sort { a, b in
        if a.span.lowerBound != b.span.lowerBound { return a.span.lowerBound < b.span.lowerBound }
        if a.span.upperBound != b.span.upperBound { return a.span.upperBound > b.span.upperBound }
        return a.change != .deleted && b.change == .deleted
    }
    return nest(items[...])
}

private func nest(_ items: ArraySlice<OutlineItem>) -> [OutlineItem] {
    var out: [OutlineItem] = []
    var i = items.startIndex
    while i < items.endIndex {
        var head = items[i]
        var j = i + 1
        while j < items.endIndex, head.contains(items[j]) { j += 1 }
        head.children = nest(items[(i + 1)..<j])
        out.append(head)
        i = j
    }
    return out
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
