import AppKit

/// The title band's subject control: what's being reviewed, which opens the picker, and the base
/// it's compared with.
@MainActor
final class SubjectControl: NSStackView {
    let subject = NSButton(title: "", target: nil, action: nil)
    let versus = NSTextField(labelWithString: "vs")
    let base = NSPopUpButton(frame: .zero, pullsDown: false)

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 4
        subject.isBordered = false
        subject.imagePosition = .imageLeading
        subject.imageHugsTitle = true
        subject.lineBreakMode = .byTruncatingMiddle
        subject.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subject.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
        subject.setAccessibilityLabel("Choose what to review")
        versus.textColor = .secondaryLabelColor
        base.isBordered = false
        base.lineBreakMode = .byTruncatingMiddle
        base.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true
        base.setContentHuggingPriority(.required, for: .horizontal)
        base.toolTip = "The branch this is compared with"
        base.setAccessibilityLabel("Compare with")
        for v in [subject, versus, base] { addArrangedSubview(v) }
        setCustomSpacing(8, after: subject)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows what's reviewed, with a chevron that marks it as a menu, and its base, or no base
    /// for subjects without one.
    func show(_ s: (title: String, symbol: String, tooltip: String), base choices: BaseChoices?) {
        let text = NSMutableAttributedString(string: s.title + " ", attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
        let chevron = NSTextAttachment()
        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: NSFont.smallSystemFontSize, weight: .semibold, scale: .small))
        text.append(NSAttributedString(attachment: chevron))
        subject.attributedTitle = text
        subject.image = NSImage(systemSymbolName: s.symbol, accessibilityDescription: nil)
        subject.toolTip = s.tooltip
        versus.isHidden = choices == nil
        base.isHidden = choices == nil
        choices?.fill(base)
    }
}

/// The classic window's title band: the title centred over a band of plain icons for the
/// navigator and inspector, what's being reviewed, and Go to Anything.
///
/// It's drawn under the system's transparent titlebar, which keeps the window's buttons, and it
/// moves the window like a titlebar does. Its parts line up with the columns below: the subject
/// starts where the code does, and Go to Anything spans the inspector.
@MainActor
final class Titlebar: FrameBar {
    let title = NSTextField(labelWithString: "")
    private let navigatorButton = Titlebar.icon("sidebar.left", "Navigator", #selector(RepoWindowController.toggleNavigatorColumn(_:)))
    private let inspectorButton = Titlebar.icon("sidebar.right", "Inspector", #selector(RepoWindowController.toggleInspectorColumn(_:)))
    let subject = SubjectControl()
    private let goToAnything = GoToAnythingField()
    private var subjectLeading: NSLayoutConstraint!
    private var goToAnythingWidth: NSLayoutConstraint!

    /// The height of the row the title and the window's buttons share.
    static let titleHeight: CGFloat = 28
    /// The height of the band of commands under the title.
    static let bandHeight: CGFloat = 38
    /// The whole title band's height.
    static let height = titleHeight + bandHeight
    private static let margin: CGFloat = 12
    private static let preferredFieldWidth: CGFloat = 220

    init() {
        super.init(edge: .minY)
        title.font = .titleBarFont(ofSize: 0)
        title.alignment = .center
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        navigatorButton.toolTip = "Show or Hide the Navigator (⌘0)"
        inspectorButton.toolTip = "Show or Hide the Inspector (⌥⌘0)"
        goToAnything.action = #selector(RepoWindowController.goToAnything(_:))
        let band = NSLayoutGuide()
        addLayoutGuide(band)
        for v in [title, navigatorButton, subject, goToAnything, inspectorButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        subjectLeading = subject.leadingAnchor.constraint(equalTo: leadingAnchor)
        subjectLeading.priority = .defaultLow
        goToAnythingWidth = goToAnything.widthAnchor.constraint(equalToConstant: Self.preferredFieldWidth)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            title.centerXAnchor.constraint(equalTo: centerXAnchor),
            title.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.titleHeight / 2),
            title.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -200),
            band.topAnchor.constraint(equalTo: topAnchor, constant: Self.titleHeight),
            band.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            navigatorButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.margin + 2),
            navigatorButton.centerYAnchor.constraint(equalTo: band.centerYAnchor),
            subjectLeading,
            subject.leadingAnchor.constraint(greaterThanOrEqualTo: navigatorButton.trailingAnchor, constant: Self.margin),
            subject.centerYAnchor.constraint(equalTo: band.centerYAnchor),
            subject.trailingAnchor.constraint(lessThanOrEqualTo: goToAnything.leadingAnchor, constant: -Self.margin),
            goToAnything.centerYAnchor.constraint(equalTo: band.centerYAnchor),
            goToAnythingWidth,
            goToAnything.trailingAnchor.constraint(equalTo: inspectorButton.leadingAnchor, constant: -10),
            inspectorButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.margin - 2),
            inspectorButton.centerYAnchor.constraint(equalTo: band.centerYAnchor),
        ])
        activityChanged()
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func icon(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: nil, action: action)
        b.isBordered = false
        b.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }

    /// Sends the band's commands to a window's controller.
    func connect(to controller: RepoWindowController) {
        for control in [navigatorButton, inspectorButton, goToAnything] as [NSControl] { control.target = controller }
        subject.subject.target = controller
        subject.subject.action = #selector(RepoWindowController.chooseSubject(_:))
        subject.base.target = controller
        subject.base.action = #selector(RepoWindowController.baseChosen(_:))
    }

    /// Lets clicks on the title reach the band, so the title moves the window too.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === title ? self : hit
    }

    /// Dims the title and icons in a window that isn't active, as titlebars do.
    override func activityChanged() {
        super.activityChanged()
        title.textColor = isActive ? .labelColor : .tertiaryLabelColor
        for b in [navigatorButton, inspectorButton] { b.contentTintColor = isActive ? .secondaryLabelColor : .tertiaryLabelColor }
    }

    /// Lines the band up with the columns below it.
    ///
    /// - Parameters:
    ///   - navigator: The navigator's width, or zero when it's hidden.
    ///   - inspector: The inspector's width, or zero when it's hidden.
    func align(navigator: CGFloat, inspector: CGFloat) {
        subjectLeading.constant = navigator > 0 ? navigator + Self.margin : 0
        subjectLeading.priority = navigator > 0 ? .defaultHigh : .defaultLow
        let spanned = inspector - Self.margin - 10 - inspectorButton.intrinsicContentSize.width - Self.margin - 2
        goToAnythingWidth.constant = inspector > 0 ? max(Self.preferredFieldWidth - 40, spanned) : Self.preferredFieldWidth
    }
}

/// A search field that opens Go to Anything instead of taking text, so the band offers it the
/// way a toolbar offers search.
@MainActor
final class GoToAnythingField: NSSearchField {
    override init(frame: NSRect) {
        super.init(frame: frame)
        placeholderString = "Go to Anything"
        refusesFirstResponder = true
        isEditable = false
        isSelectable = false
        toolTip = "Go to a file, definition, line or command (⌘K)"
        setAccessibilityRole(.button)
        setAccessibilityLabel("Go to Anything")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { sendAction(action, to: target) }

    override func accessibilityPerformPress() -> Bool { sendAction(action, to: target) }
}
