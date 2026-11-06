import AppKit

/// The bar along the bottom of the classic window: what part of the review is being read, and
/// how much of it is reviewed.
@MainActor
final class StatusBar: FrameBar {
    let summary = NSTextField(labelWithString: "")
    let progress = NSTextField(labelWithString: "")

    static let height: CGFloat = 24

    init() {
        super.init(edge: .maxY)
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
        for label in [summary, progress] {
            label.font = font
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        progress.font = .monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
        progress.alignment = .right
        progress.setContentCompressionResistancePriority(.required, for: .horizontal)
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            summary.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            summary.centerYAnchor.constraint(equalTo: centerYAnchor),
            summary.trailingAnchor.constraint(lessThanOrEqualTo: progress.leadingAnchor, constant: -12),
            progress.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            progress.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows the part of the review being read and how many of its files are reviewed.
    func show(summary text: String, reviewed: Int, of total: Int) {
        summary.stringValue = text
        progress.stringValue = total == 0 ? "" : "\(reviewed) of \(total) reviewed"
    }
}
