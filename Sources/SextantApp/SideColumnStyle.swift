import AppKit

/// The fonts of the navigator and inspector, from the system's text styles, so the side
/// columns read like the system's own sidebars, though in the theme's colours.
extension NSFont {
    /// A quiet section label, like a sidebar's group headings, in sentence case.
    static var sectionLabel: NSFont {
        let subheadline = NSFont.preferredFont(forTextStyle: .subheadline)
        return .systemFont(ofSize: subheadline.pointSize, weight: .medium)
    }

    /// A row's main text.
    static var row: NSFont { .preferredFont(forTextStyle: .body) }

    /// What a row says beside or under its main text, such as a folder, an author or a date.
    static var detail: NSFont { .preferredFont(forTextStyle: .callout) }

    /// Counts and change sizes beside a row's text, with digits that line up.
    static var detailDigits: NSFont { .monospacedDigitSystemFont(ofSize: detail.pointSize, weight: .regular) }

    /// Hashes and line numbers beside a row's text, in the code's style.
    static var detailCode: NSFont { .monospacedSystemFont(ofSize: detail.pointSize, weight: .regular) }
}

/// A side column's row, whose selection is a raised capsule of the theme's selection pill, with
/// a hairline and, in light, a soft shadow. Selected text keeps its colour.
final class PillRowView: NSTableRowView {
    /// How far the capsule keeps in from the column's edges.
    static let inset: CGFloat = 7

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        let theme = Appearance.shared.theme(for: effectiveAppearance)
        let pill = bounds.insetBy(dx: Self.inset, dy: 1)
        let shape = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2)
        NSGraphicsContext.saveGraphicsState()
        if !theme.isDark {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.themed("fg").withAlphaComponent(0.08)
            shadow.shadowBlurRadius = 3.5
            shadow.shadowOffset = NSSize(width: 0, height: -1.5)
            shadow.set()
        }
        theme.color("selectionPill").setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        theme.color("selectionPillStroke").setStroke()
        let edge = NSBezierPath(roundedRect: pill.insetBy(dx: 0.25, dy: 0.25), xRadius: pill.height / 2, yRadius: pill.height / 2)
        edge.lineWidth = 0.5
        edge.stroke()
    }
}
