import AppKit

/// A quiet message where content would be: a faint symbol over a muted line of text, centred in
/// the space it's placed in.
@MainActor
final class EmptyState: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")

    /// Makes an empty state at a size for where it sits.
    ///
    /// - Parameters:
    ///   - symbolSize: The symbol's point size.
    ///   - font: The message's font.
    init(symbolSize: CGFloat, font: NSFont) {
        super.init(frame: .zero)
        icon.symbolConfiguration = .init(pointSize: symbolSize, weight: .light)
        icon.contentTintColor = .themed("fgSubtle")
        label.font = font
        label.textColor = .themed("fgMuted")
        label.alignment = .center
        label.isSelectable = false
        let column = NSStackView(views: [icon, label])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = symbolSize / 3
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows a message under a symbol.
    ///
    /// - Parameters:
    ///   - message: What's missing or why.
    ///   - symbol: The SF Symbol's name.
    func show(_ message: String, symbol: String) {
        label.stringValue = message
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        setAccessibilityLabel(message)
    }
}
