import AppKit
import SextantCore

/// A pane's header: what the pane shows, as its file or All Changes with the folders it's in and
/// the definition at the caret, the size of the change, and what can be done to the pane.
///
/// The title and each folder open a menu of what sits beside them in the snapshot, like Xcode's
/// jump bar. The pane's buttons show its diff layout and whether its file is reviewed, and zoom
/// and close it.
@MainActor
final class PaneHeader: NSView, NSMenuDelegate {
    private let title = NSButton(title: "", target: nil, action: nil)
    private let folders = NSStackView()
    let symbols = NSPopUpButton(frame: .zero, pullsDown: true)
    private let symbolChevron = PaneHeader.chevron()
    let stats = NSTextField(labelWithString: "")
    let splitButton = QuietButton.make("rectangle.split.2x1", "Side by Side")
    let reviewedButton = QuietButton.make("checkmark.circle", "Mark as Reviewed")
    let zoomButton = QuietButton.make("arrow.up.left.and.arrow.down.right", "Zoom Pane")
    let closeButton = QuietButton.make("xmark", "Close Pane")
    /// Every file in the snapshot, sorted, for the folder menus.
    var tree: [String] = []
    private(set) var currentFile: Int?
    private(set) var definitions: [Symbol] = []
    private var shownPath: String?
    private var shownKey = ""
    private var showsOverview = false
    private var isReviewed = false {
        didSet { if isReviewed != oldValue { applyEmphasis() } }
    }
    private var symbolMenuIsCurrent = false
    var onOpenPath: ((String) -> Void)?
    var onShowOverview: (() -> Void)?
    var onSelectSymbol: ((Symbol) -> Void)?
    var onToggleSplit: (() -> Void)?
    var onToggleReviewed: (() -> Void)?
    var onToggleZoom: (() -> Void)?
    var onClose: (() -> Void)?

    private let style: PaneHeaderStyle
    private var row = NSStackView()

    /// How far the content keeps in from each end, clear of the titlebar controls over the header.
    var clearance = NSEdgeInsetsZero {
        didSet {
            guard clearance.left != oldValue.left || clearance.right != oldValue.right else { return }
            row.edgeInsets = rowInsets
        }
    }

    private var rowInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 12 + clearance.left, bottom: 0, right: 14 + clearance.right)
    }

    /// Whether this is the pane the keyboard and side columns follow, which the header shows in
    /// full while the others fade.
    var isFocusedPane = true {
        didSet {
            guard isFocusedPane != oldValue else { return }
            applyEmphasis()
            needsDisplay = true
        }
    }

    private static func chevron() -> NSImageView {
        let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.compact.right", accessibilityDescription: nil)!)
        chevron.symbolConfiguration = .init(textStyle: .body, scale: .small)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        chevron.contentTintColor = .themed("fgSubtle")
        return chevron
    }

    /// Shows the pane's diff layout and the zoom and close buttons, which depend on the window
    /// rather than the files shown.
    ///
    /// - Parameters:
    ///   - split: Whether the pane shows changes side by side.
    ///   - beside: Whether other panes share the strip, without which zoom and close have nothing
    ///     to do.
    ///   - zoomed: Whether the strip is zoomed to one pane at a time.
    func setPane(split: Bool, beside: Bool, zoomed: Bool) {
        splitButton.image = NSImage(systemSymbolName: split ? "text.justify.leading" : "rectangle.split.2x1", accessibilityDescription: nil)
        splitButton.toolTip = split ? "Show Unified (⌃⌘1)" : "Show Side by Side (⌃⌘2)"
        splitButton.setAccessibilityLabel(splitButton.toolTip)
        zoomButton.image = NSImage(systemSymbolName: zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil)
        zoomButton.toolTip = zoomed ? "Show Panes Side by Side (⇧⌘↩)" : "Zoom Pane (⇧⌘↩)"
        zoomButton.setAccessibilityLabel(zoomButton.toolTip)
        zoomButton.isHidden = !beside
        closeButton.isHidden = !beside
    }

    init(style: PaneHeaderStyle) {
        self.style = style
        super.init(frame: .zero)
        splitButton.target = self
        splitButton.action = #selector(splitClicked)
        reviewedButton.target = self
        reviewedButton.action = #selector(reviewedClicked)
        zoomButton.target = self
        zoomButton.action = #selector(zoomClicked)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "Close Pane (⌘W)"
        reviewedButton.isHidden = true
        title.isBordered = false
        title.target = self
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        title.imagePosition = .imageLeading
        title.imageHugsTitle = true
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow + 2, for: .horizontal)
        folders.orientation = .horizontal
        folders.spacing = 2
        folders.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        folders.setHuggingPriority(.required, for: .horizontal)
        symbols.isBordered = false
        symbols.font = .systemFont(ofSize: NSFont.systemFontSize)
        (symbols.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        symbols.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        symbols.isHidden = true
        symbols.menu = NSMenu()
        symbols.menu?.addItem(withTitle: "", action: nil, keyEquivalent: "")
        symbols.menu?.delegate = self
        stats.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        stats.setContentCompressionResistancePriority(.required, for: .horizontal)
        stats.setContentHuggingPriority(.required, for: .horizontal)
        symbolChevron.isHidden = true
        row = NSStackView(views: [title, folders, symbolChevron, symbols, NSView(), stats, reviewedButton, splitButton, zoomButton, closeButton])
        row.orientation = .horizontal
        row.spacing = 0
        row.setCustomSpacing(10, after: title)
        row.setCustomSpacing(2, after: folders)
        row.setCustomSpacing(2, after: symbolChevron)
        row.setCustomSpacing(14, after: stats)
        row.setCustomSpacing(12, after: reviewedButton)
        row.setCustomSpacing(12, after: splitButton)
        row.setCustomSpacing(12, after: zoomButton)
        row.edgeInsets = rowInsets
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: style.height),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyEmphasis()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Fills the header as a bar over its pane, with a hairline along its foot, when its look
    /// draws it as one.
    override func draw(_ dirtyRect: NSRect) {
        guard let bar = style.bar else { return }
        (isFocusedPane ? bar.focused : bar.other).setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    /// Zooms or minimizes the window on a double click when the header lies in the titlebar, as
    /// the titlebar would, following the user's setting for it.
    override func mouseDown(with event: NSEvent) {
        guard style.liesInTitlebar, event.clickCount == 2, let window else { super.mouseDown(with: event); return }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
    }

    /// Colours the header for whether its pane is focused: the title in full and the rest grey,
    /// or everything a step fainter.
    private func applyEmphasis() {
        let strong = NSColor.themed(isFocusedPane ? "fg" : "fgMuted")
        let quiet = NSColor.themed(isFocusedPane ? "fgMuted" : "fgSubtle")
        title.contentTintColor = strong
        for b in folderButtons { b.contentTintColor = quiet }
        symbols.contentTintColor = quiet
        reviewedButton.idleTint = .themed(isReviewed ? "fgMuted" : "fgFaint")
        reviewedButton.brightensOnHover = !isReviewed
        stats.alphaValue = isFocusedPane ? 0.85 : 0.5
    }

    /// The path shown, as folders then the file, after All Changes in the overview.
    var components: [String] {
        (showsOverview ? [title.title] : []) + folders.arrangedSubviews.compactMap { ($0 as? NSButton)?.title } + (showsOverview || shownPath == nil ? [] : [title.title])
    }

    func update(path p: String?, files: [ShownFile], current: Int?, style: Style) {
        let text = p == nil ? nil : files.first?.text
        let reviewable = current.flatMap { files.indices.contains($0) ? files[$0].file : nil }.flatMap { $0.isChange ? $0 : nil }
        let key = "\(p ?? "\u{0}")|\(current ?? -1)|\(reviewable.map { $0.reviewed ? "r" : "u" } ?? "-")|\(text?.definitions?.count ?? -1)|\(files.count):\(files.first.map { ObjectIdentifier($0.file).hashValue } ?? 0):\(files.last.map { ObjectIdentifier($0.file).hashValue } ?? 0):\(text.map { ObjectIdentifier($0).hashValue } ?? 0)|\(style.theme.name)|\(style.theme.color("success"))|\(style.theme.color("danger"))"
        guard key != shownKey else { return }
        shownKey = key
        currentFile = current
        let shown = p ?? current.map { files[$0].file.path }
        shownPath = shown
        showsOverview = p == nil
        let comps = shown.map { $0.split(separator: "/").map(String.init) } ?? []
        if showsOverview {
            setTitle("All Changes", image: NSImage(systemSymbolName: "square.stack", accessibilityDescription: nil), action: #selector(overviewClicked))
            showFolders(comps)
        } else {
            setTitle(comps.last ?? "", image: shown.map(fileIcon), action: #selector(crumbClicked(_:)))
            title.tag = comps.count - 1
            showFolders(Array(comps.dropLast()))
        }
        toolTip = shown
        let addDel: (Int, Int)
        if p == nil {
            addDel = files.reduce((0, 0)) { ($0.0 + $1.file.diff.additions, $0.1 + $1.file.diff.deletions) }
        } else {
            addDel = files.first.map { ($0.file.diff.additions, $0.file.diff.deletions) } ?? (0, 0)
        }
        let s = NSMutableAttributedString(string: "+\(addDel.0)", attributes: [.foregroundColor: style.theme.color("success")])
        s.append(NSAttributedString(string: "  −\(addDel.1)", attributes: [.foregroundColor: style.theme.color("danger")]))
        stats.attributedStringValue = s
        stats.isHidden = !files.contains(where: \.file.isChange)
        reviewedButton.isHidden = reviewable == nil
        isReviewed = reviewable?.reviewed == true
        reviewedButton.image = NSImage(systemSymbolName: isReviewed ? "checkmark.circle.fill" : "checkmark.circle", accessibilityDescription: nil)
        reviewedButton.toolTip = isReviewed ? "Mark as Not Reviewed (R)" : "Mark as Reviewed (R)"
        reviewedButton.setAccessibilityLabel(reviewedButton.toolTip)
        definitions = text?.definitions ?? []
        symbolMenuIsCurrent = false
        symbols.isHidden = true
        symbolChevron.isHidden = true
    }

    private func setTitle(_ text: String, image: NSImage?, action: Selector) {
        if title.title != text { title.title = text }
        if title.image !== image { title.image = image }
        title.action = action
    }

    private var folderButtons: [NSButton] = []
    private var separators: [NSImageView] = []

    /// Shows the folders after the title in grey, separated by chevrons, reusing the views
    /// already made, since making controls costs more than changing them.
    ///
    /// Each folder's tag is its index in the shown path, which its menu lists the parent of.
    private func showFolders(_ names: [String]) {
        while folderButtons.count < names.count { folderButtons.append(makeFolderButton()) }
        while separators.count < names.count - 1 { separators.append(Self.chevron()) }
        var views: [NSView] = []
        for (i, name) in names.enumerated() {
            if i > 0 { views.append(separators[i - 1]) }
            let b = folderButtons[i]
            if b.title != name { b.title = name }
            b.tag = i
            views.append(b)
        }
        guard folders.arrangedSubviews != views else { return }
        for v in folders.arrangedSubviews where !views.contains(v) { v.removeFromSuperview() }
        for (i, v) in views.enumerated() where i >= folders.arrangedSubviews.count || folders.arrangedSubviews[i] !== v {
            folders.insertArrangedSubview(v, at: i)
        }
    }

    private func makeFolderButton() -> NSButton {
        let b = NSButton(title: "", target: self, action: #selector(crumbClicked(_:)))
        b.isBordered = false
        b.font = .systemFont(ofSize: NSFont.systemFontSize)
        b.lineBreakMode = .byTruncatingMiddle
        b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        b.contentTintColor = .themed(isFocusedPane ? "fgMuted" : "fgSubtle")
        return b
    }

    /// Lists the file's definitions under the menu's title item, indented by nesting, when the
    /// menu opens rather than on every file change, since a long file has hundreds.
    private func fillSymbolMenu(_ menu: NSMenu) {
        guard !symbolMenuIsCurrent, let title = menu.items.first else { return }
        symbolMenuIsCurrent = true
        var items = [title]
        var enclosing: [Symbol] = []
        for (i, d) in definitions.enumerated() {
            while let outer = enclosing.last, NSMaxRange(outer.range) < NSMaxRange(d.range) { enclosing.removeLast() }
            let item = NSMenuItem(title: d.name, action: #selector(symbolChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.indentationLevel = min(enclosing.count, 6)
            item.image = Self.image(forKind: d.kind)
            items.append(item)
            enclosing.append(d)
        }
        menu.items = items
    }

    private static var images: [String: NSImage] = [:]

    private static func image(forKind kind: String) -> NSImage? {
        if let cached = images[kind] { return cached }
        let made = NSImage(systemSymbolName: symbolImage(kind), accessibilityDescription: kind)
        images[kind] = made
        return made
    }

    /// Returns the innermost definition around a zero-based, new-side line.
    func enclosing(line: Int) -> Symbol? {
        definitions.last { $0.lines.contains(line) }
    }

    /// Shows the definition enclosing a zero-based, new-side line after the path.
    func updateSymbol(line: Int?) {
        guard !definitions.isEmpty, let line, let enclosing = enclosing(line: line) else {
            symbols.isHidden = true
            symbolChevron.isHidden = true
            return
        }
        symbols.isHidden = false
        symbols.menu?.item(at: 0)?.title = enclosing.name
        symbols.menu?.item(at: 0)?.image = Self.image(forKind: enclosing.kind)
        symbols.synchronizeTitleAndSelectedItem()
        symbols.setTitle(enclosing.name)
        symbolChevron.isHidden = false
    }

    @objc private func symbolChosen(_ sender: NSMenuItem) {
        guard sender.tag < definitions.count else { return }
        onSelectSymbol?(definitions[sender.tag])
    }

    /// Opens the definitions menu, from the keyboard.
    func showSymbolMenu() {
        guard !definitions.isEmpty else { beep(); return }
        let wasHidden = symbols.isHidden
        if wasHidden {
            symbols.menu?.item(at: 0)?.title = "Definitions"
            symbols.isHidden = false
            layoutSubtreeIfNeeded()
        }
        symbols.performClick(nil)
        if wasHidden { symbols.isHidden = true }
    }

    @objc private func overviewClicked() { onShowOverview?() }
    @objc private func splitClicked() { onToggleSplit?() }
    @objc private func reviewedClicked() { onToggleReviewed?() }
    @objc private func zoomClicked() { onToggleZoom?() }
    @objc private func closeClicked() { onClose?() }

    @objc private func crumbClicked(_ sender: NSButton) {
        guard let shownPath else { return }
        let comps = shownPath.split(separator: "/").map(String.init)
        let dir = comps.prefix(sender.tag).joined(separator: "/")
        let menu = NSMenu(title: dir)
        menu.delegate = self
        menuNeedsUpdate(menu)
        let selected = menu.items.first { $0.state == .on }
        menu.popUp(positioning: selected, at: NSPoint(x: 0, y: sender.bounds.maxY + 2), in: sender)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === symbols.menu {
            fillSymbolMenu(menu)
        } else {
            fillFolderMenu(menu)
        }
    }

    /// Fills a folder's menu with the folders and files directly inside it.
    private func fillFolderMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let dir = menu.title
        let prefix = dir.isEmpty ? "" : dir + "/"
        var folders: [String] = [], files: [String] = []
        var seen = Set<String>()
        for p in tree where p.hasPrefix(prefix) {
            let rest = p.dropFirst(prefix.count)
            if let slash = rest.firstIndex(of: "/") {
                let name = String(rest[..<slash])
                if seen.insert(name).inserted { folders.append(name) }
            } else {
                files.append(String(rest))
            }
        }
        let order: (String, String) -> Bool = { $0.localizedStandardCompare($1) == .orderedAscending }
        let folderIcon = NSWorkspace.shared.icon(for: .folder)
        folderIcon.size = NSSize(width: 16, height: 16)
        for name in folders.sorted(by: order) {
            let item = menu.addItem(withTitle: name, action: nil, keyEquivalent: "")
            item.image = folderIcon
            let sub = NSMenu(title: prefix + name)
            sub.delegate = self
            item.submenu = sub
            if shownPath?.hasPrefix(prefix + name + "/") == true { item.state = .on }
        }
        for name in files.sorted(by: order) {
            let item = menu.addItem(withTitle: name, action: #selector(fileChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = prefix + name
            item.image = fileIcon(name)
            if shownPath == prefix + name { item.state = .on }
        }
        if menu.items.isEmpty { menu.addItem(withTitle: "Empty", action: nil, keyEquivalent: "").isEnabled = false }
    }

    @objc private func fileChosen(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? String else { return }
        onOpenPath?(p)
    }
}

/// A borderless symbol button in a quiet tint that comes up a step while the pointer is over it.
@MainActor
final class QuietButton: NSButton {
    /// The tint while the pointer is elsewhere.
    var idleTint: NSColor = .themed("fgFaint") { didSet { applyTint() } }
    /// The tint while the pointer is over the button.
    var hoverTint: NSColor = .themed("fgMuted") { didSet { applyTint() } }
    /// Whether the tint comes up under the pointer, which a button showing a state in colour,
    /// such as a reviewed file's check, turns off.
    var brightensOnHover = true { didSet { applyTint() } }
    private var isHovered = false { didSet { applyTint() } }
    private var hoverArea: NSTrackingArea?

    /// Makes a button showing a symbol, sized to the body text.
    ///
    /// - Parameters:
    ///   - symbol: The SF Symbol's name.
    ///   - label: What the button does, for its tooltip and accessibility.
    static func make(_ symbol: String, _ label: String) -> QuietButton {
        let b = QuietButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: nil, action: nil)
        b.isBordered = false
        b.symbolConfiguration = .init(textStyle: .body, scale: .medium)
        b.toolTip = label
        b.setContentHuggingPriority(.required, for: .horizontal)
        b.setContentCompressionResistancePriority(.required, for: .horizontal)
        b.applyTint()
        return b
    }

    private func applyTint() {
        contentTintColor = isHovered && brightensOnHover && isEnabled ? hoverTint : idleTint
    }

    override var isEnabled: Bool {
        didSet { applyTint() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }

    override func mouseExited(with event: NSEvent) { isHovered = false }
}
