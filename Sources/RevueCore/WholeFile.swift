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
