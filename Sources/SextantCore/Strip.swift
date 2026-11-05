import Foundation

/// Returns how far a strip of side-by-side panes scrolls so one pane is wholly in view, moving
/// as little as it can.
///
/// A pane to the right comes in at the right edge, so the pane before it stays in view at the
/// left; a pane to the left comes in at the left edge.
///
/// - Parameters:
///   - index: The pane to bring into view.
///   - offset: How far the strip is scrolled now.
///   - paneWidth: Each pane's width.
///   - gap: The space between neighbouring panes.
///   - viewport: The width that shows.
///   - total: The width of every pane together, with the gaps between them.
public func stripOffset(showing index: Int, from offset: CGFloat, paneWidth: CGFloat, gap: CGFloat, viewport: CGFloat, total: CGFloat) -> CGFloat {
    let minX = CGFloat(index) * (paneWidth + gap), maxX = minX + paneWidth
    var o = offset
    if minX < o { o = minX }
    if maxX > o + viewport { o = maxX - viewport }
    return max(0, min(o, max(0, total - viewport)))
}
