import Foundation

/// Returns the complete file as one line sequence.
///
/// The result is the hunks, with the unchanged lines of the old file filled in around and
/// between them.
public func wholeFile(_ hunks: [Hunk], oldLines old: [String]) -> [DiffLine] {
    var out: [DiffLine] = []
    out.reserveCapacity(old.count + hunks.reduce(0) { $0 + $1.lines.count })
    var nextOld = 1, nextNew = 1
    func context(through last: Int) {
        guard last >= nextOld else { return }
        for no in nextOld...last {
            out.append(DiffLine(kind: .context, oldNo: no, newNo: nextNew, text: no - 1 < old.count ? old[no - 1] : ""))
            nextNew += 1
        }
        nextOld = last + 1
    }
    for h in hunks {
        context(through: h.oldCount == 0 ? h.oldStart : h.oldStart - 1)
        for l in h.lines {
            out.append(l)
            if l.oldNo > 0 { nextOld = l.oldNo + 1 }
            if l.newNo > 0 { nextNew = l.newNo + 1 }
        }
    }
    context(through: old.count)
    return out
}

/// Returns how many unchanged lines a diff leaves out before each hunk, after the hunk before it.
///
/// These are the lines `wholeFile(_:oldLines:)` fills in there. Lines after the last hunk aren't
/// counted, since the hunks don't say where the file ends.
public func unchangedLinesBefore(_ hunks: [Hunk]) -> [Int] {
    var nextOld = 1
    return hunks.map { h in
        let last = h.oldCount == 0 ? h.oldStart : h.oldStart - 1
        defer { nextOld = h.oldCount == 0 ? max(nextOld, h.oldStart + 1) : h.oldEnd }
        return max(0, last - nextOld + 1)
    }
}

/// Returns the runs of unchanged lines to hide when showing only the changes.
///
/// Runs shorter than `minimum` stay visible, since folding them would save nothing. A file
/// without changes has nothing to fold.
///
/// - Parameters:
///   - context: The number of unchanged lines to keep visible around each change.
///   - minimum: The shortest run worth folding.
public func foldedRuns(_ lines: [DiffLine], context: Int, minimum: Int = 4) -> [Range<Int>] {
    guard lines.contains(where: { $0.kind != .context }) else { return [] }
    var out: [Range<Int>] = []
    var i = 0
    while i < lines.count {
        guard lines[i].kind == .context else { i += 1; continue }
        var j = i
        while j < lines.count, lines[j].kind == .context { j += 1 }
        let lo = i == 0 ? i : i + context
        let hi = j == lines.count ? j : j - context
        if hi - lo >= minimum { out.append(lo..<hi) }
        i = j
    }
    return out
}

/// Where a diff's lines are by their line numbers, and where each line stands on the new side.
///
/// Built in one pass, so finding a line by its number costs nothing however long the text is.
/// A removed line has no new-side number (`newNo` is 0), and an added line no old-side one.
public struct LinePositions: Sendable {
    private let newIndex: [Int32]
    private let oldIndex: [Int32]
    private let halfLines: [Int32]
    /// The highest new-side line number, or 0 if no line is on the new side.
    public let lastNew: Int
    /// The highest old-side line number, or 0 if no line is on the old side.
    public let lastOld: Int

    public init(_ lines: [DiffLine]) {
        let lastNew = lines.lazy.filter { $0.kind != .deleted }.map(\.newNo).max() ?? 0
        let lastOld = lines.lazy.filter { $0.kind != .added }.map(\.oldNo).max() ?? 0
        var newIndex = [Int32](repeating: -1, count: lastNew + 1)
        var oldIndex = [Int32](repeating: -1, count: lastOld + 1)
        var halfLines = [Int32](repeating: 0, count: lines.count)
        var before: Int32 = -2
        for (i, l) in lines.enumerated() {
            if l.kind != .deleted, l.newNo > 0, newIndex[l.newNo] < 0 { newIndex[l.newNo] = Int32(i) }
            if l.kind != .added, l.oldNo > 0, oldIndex[l.oldNo] < 0 { oldIndex[l.oldNo] = Int32(i) }
            if l.kind == .deleted {
                halfLines[i] = before + 1
            } else {
                before = Int32(2 * (l.newNo - 1))
                halfLines[i] = before
            }
        }
        self.newIndex = newIndex
        self.oldIndex = oldIndex
        self.halfLines = halfLines
        self.lastNew = lastNew
        self.lastOld = lastOld
    }

    /// Returns the index of the line with a 1-based number on one side, if the lines hold it.
    public func index(ofLine n: Int, old: Bool) -> Int? {
        let table = old ? oldIndex : newIndex
        guard table.indices.contains(n), table[n] >= 0 else { return nil }
        return Int(table[n])
    }

    /// Returns where a line stands on the new side, in half lines: `2 * (newNo - 1)` for a line
    /// the new side has, and one more than the new-side line before it for a removed line, so
    /// it sorts between the lines around it.
    public func newSideHalfLine(at index: Int) -> Int { Int(halfLines[index]) }

    /// Returns the zero-based new-side line a line is on, or for a removed line the one before
    /// it, as what holds the removal: 0 if none is.
    public func newSideLine(at index: Int) -> Int { max(0, Int(halfLines[index]) / 2) }
}
