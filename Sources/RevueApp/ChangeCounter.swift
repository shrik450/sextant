import AppKit

/// A glass capsule at the foot of the focused card that says which change the reader is at, with
/// buttons for the previous and next change.
///
/// The buttons send the Previous Change and Next Change commands, so they behave exactly like
/// the menu items and their shortcuts.
@MainActor
final class ChangeCounter: NSView {
    static let height: CGFloat = 28
    /// How far the capsule floats above the foot of the card.
    static let margin: CGFloat = 12
    /// How much room the code leaves below its last line, so the capsule never covers it.
    static let clearance: CGFloat = height + margin * 2

    private let glass = NSGlassEffectView()
    private let label = NSTextField(labelWithString: "")
    private let previous = ChangeCounter.button("chevron.up", "Previous Change (⇧K)", #selector(RepoWindowController.previousChange(_:)))
    private let next = ChangeCounter.button("chevron.down", "Next Change (⇧J)", #selector(RepoWindowController.nextChange(_:)))

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.textColor = .themed("fgMuted")
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: [previous, label, next])
        row.orientation = .horizontal
        row.spacing = 4
        row.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        glass.cornerRadius = Self.height / 2
        glass.contentView = row
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func button(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let b = QuietButton.make(symbol, label)
        b.action = action
        b.refusesFirstResponder = true
        b.symbolConfiguration = .init(pointSize: NSFont.smallSystemFontSize, weight: .semibold)
        b.idleTint = .themed("fgMuted")
        b.hoverTint = .themed("fg")
        b.widthAnchor.constraint(equalToConstant: 20).isActive = true
        return b
    }

    /// Shows where the reader is among the changes.
    ///
    /// - Parameters:
    ///   - ordinal: The change the reader is in or below, from 1, or 0 above the first.
    ///   - count: The number of changes.
    ///   - canGoBack: Whether Previous Change has a change to move to.
    ///   - canGoForward: Whether Next Change has a change to move to.
    func show(_ ordinal: Int, of count: Int, canGoBack: Bool, canGoForward: Bool) {
        label.stringValue = ordinal == 0 ? (count == 1 ? "1 change" : "\(count) changes") : "Change \(ordinal) of \(count)"
        setAccessibilityLabel(label.stringValue)
        previous.isEnabled = canGoBack
        next.isEnabled = canGoForward
    }
}
