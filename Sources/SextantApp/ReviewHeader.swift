import AppKit
import SextantCore

/// The top of the navigator, which says what the window reviews: the repository, the subject,
/// which opens the picker, the part of it being read, and the base it's compared with.
@MainActor
final class ReviewHeader: NSView {
    let repository = NSTextField(labelWithString: "")
    let subject = NSButton(title: "", target: nil, action: nil)
    let scope = NSTextField(labelWithString: "")
    let base = NSPopUpButton(frame: .zero, pullsDown: false)
    private let chooser = NSImageView(image: NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)!)
    private let baseRow: NSStackView

    override init(frame: NSRect) {
        let versus = NSTextField(labelWithString: "Compared with")
        baseRow = NSStackView(views: [versus, base])
        super.init(frame: frame)
        repository.font = .sectionLabel
        repository.textColor = .themed("fgMuted")
        repository.lineBreakMode = .byTruncatingTail
        subject.isBordered = false
        subject.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        subject.imagePosition = .imageLeading
        subject.imageHugsTitle = true
        subject.alignment = .left
        subject.lineBreakMode = .byTruncatingMiddle
        subject.symbolConfiguration = .init(textStyle: .body, scale: .medium)
        subject.contentTintColor = .themed("fg")
        subject.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subject.setAccessibilityLabel("Choose what to review")
        chooser.symbolConfiguration = .init(textStyle: .body, scale: .small)
        chooser.contentTintColor = .themed("fgMuted")
        chooser.setContentHuggingPriority(.required, for: .horizontal)
        chooser.setContentCompressionResistancePriority(.required, for: .horizontal)
        scope.font = .detail
        scope.textColor = .themed("fgMuted")
        scope.lineBreakMode = .byTruncatingTail
        scope.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        versus.font = .detail
        versus.textColor = .themed("fgMuted")
        versus.setContentHuggingPriority(.required, for: .horizontal)
        base.isBordered = false
        base.font = .detail
        base.lineBreakMode = .byTruncatingMiddle
        base.contentTintColor = .themed("fg")
        base.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        base.toolTip = "The branch this is compared with"
        base.setAccessibilityLabel("Compare with")
        baseRow.orientation = .horizontal
        baseRow.spacing = 2
        let subjectRow = NSStackView(views: [subject, chooser])
        subjectRow.orientation = .horizontal
        subjectRow.spacing = 4
        let column = NSStackView(views: [repository, subjectRow, scope, baseRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.setCustomSpacing(6, after: repository)
        column.setCustomSpacing(4, after: subjectRow)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            subjectRow.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
            scope.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
            baseRow.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows the repository, what's reviewed, the part of it being read and its base.
    func show(_ summary: ReviewSummary) {
        repository.stringValue = summary.repository
        subject.title = summary.subject.title
        subject.image = NSImage(systemSymbolName: summary.subject.symbol, accessibilityDescription: nil)
        subject.toolTip = summary.subject.tooltip
        scope.stringValue = summary.scope
        scope.isHidden = summary.scope.isEmpty
        baseRow.isHidden = summary.base == nil
        summary.base?.fill(base)
    }
}
