import AppKit
import RevueCore

/// A pane's header: where the pane is, as folders, file and definition, the size of the change,
/// and what can be done to the pane.
///
/// Each folder or file opens a menu of what sits beside it in the snapshot, like Xcode's jump bar.
/// The pane's buttons show its diff layout, whether its file is reviewed, and close it.
@MainActor
final class PaneHeader: NSView, NSMenuDelegate {
    private let crumbs = NSStackView()
    let symbols = NSPopUpButton(frame: .zero, pullsDown: true)
    private let symbolChevron = NSImageView(image: NSImage(systemSymbolName: "chevron.compact.right", accessibilityDescription: nil)!)
    let stats = NSTextField(labelWithString: "")
    let splitButton = PaneHeader.button("rectangle.split.2x1", "Side by Side")
    let reviewedButton = PaneHeader.button("checkmark.circle", "Mark as Reviewed")
    let closeButton = PaneHeader.button("xmark", "Close Pane")
    /// Every file in the snapshot, sorted, for the folder menus.
    var tree: [String] = []
    private(set) var currentFile: Int?
    private(set) var definitions: [Symbol] = []
    private var shownPath: String?
    private var shownKey = ""
    private var symbolMenuIsCurrent = false
    var onOpenPath: ((String) -> Void)?
    var onShowOverview: (() -> Void)?
    var onSelectSymbol: ((Symbol) -> Void)?
    var onToggleSplit: (() -> Void)?
    var onToggleReviewed: (() -> Void)?
    var onClose: (() -> Void)?

    /// Whether this is the pane the keyboard and side columns follow, which the header shows by
    /// dimming the others.
    var isFocusedPane = true {
        didSet {
            guard isFocusedPane != oldValue else { return }
            for b in buttons { b.contentTintColor = crumbColor }
        }
    }

    private var crumbColor: NSColor { isFocusedPane ? .labelColor : .secondaryLabelColor }

    private static func button(_ symbol: String, _ label: String) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: nil, action: nil)
        b.isBordered = false
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = label
        b.setContentHuggingPriority(.required, for: .horizontal)
        b.setContentCompressionResistancePriority(.required, for: .horizontal)
        return b
    }

    /// Shows the pane's diff layout and whether it can close, which depend on the window rather
    /// than the files shown.
    func setPane(split: Bool, canClose: Bool) {
        splitButton.image = NSImage(systemSymbolName: split ? "text.justify.leading" : "rectangle.split.2x1", accessibilityDescription: nil)
        splitButton.toolTip = split ? "Show Unified (⌃⌘1)" : "Show Side by Side (⌃⌘2)"
        splitButton.setAccessibilityLabel(splitButton.toolTip)
        closeButton.isHidden = !canClose
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        splitButton.target = self
        splitButton.action = #selector(splitClicked)
        reviewedButton.target = self
        reviewedButton.action = #selector(reviewedClicked)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "Close Pane (⌘W)"
        reviewedButton.isHidden = true
        crumbs.orientation = .horizontal
        crumbs.spacing = 0
        crumbs.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        symbols.isBordered = false
        symbols.controlSize = .small
        symbols.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        (symbols.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        symbols.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        symbols.isHidden = true
        symbols.menu = NSMenu()
        symbols.menu?.addItem(withTitle: "", action: nil, keyEquivalent: "")
        symbols.menu?.delegate = self
        stats.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        stats.setContentCompressionResistancePriority(.required, for: .horizontal)
        stats.setContentHuggingPriority(.required, for: .horizontal)
        symbolChevron.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        symbolChevron.contentTintColor = .tertiaryLabelColor
        symbolChevron.isHidden = true
        let row = NSStackView(views: [crumbs, symbolChevron, symbols, NSView(), stats, reviewedButton, splitButton, closeButton])
        row.orientation = .horizontal
        row.spacing = 0
        row.setCustomSpacing(12, after: stats)
        row.setCustomSpacing(10, after: reviewedButton)
        row.setCustomSpacing(10, after: splitButton)
        row.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    /// The path shown, as folders then the file.
    var components: [String] { crumbs.arrangedSubviews.compactMap { ($0 as? NSButton)?.title } }

    func update(path p: String?, files: [FileState], current: Int?, style: Style) {
        let reviewable = current.flatMap { files.indices.contains($0) ? files[$0] : nil }.flatMap { $0.isChange ? $0 : nil }
        let key = "\(p ?? "\u{0}")|\(current ?? -1)|\(reviewable.map { $0.reviewed ? "r" : "u" } ?? "-")|\(p == nil ? -1 : files.first?.definitions?.count ?? -1)|\(files.count):\(files.first.map { ObjectIdentifier($0).hashValue } ?? 0):\(files.last.map { ObjectIdentifier($0).hashValue } ?? 0):\(p == nil ? 0 : files.first?.lines.count ?? 0)|\(style.theme.name)|\(style.theme.color("success"))|\(style.theme.color("danger"))"
        guard key != shownKey else { return }
        shownKey = key
        currentFile = current
        let shown = p ?? current.map { files[$0].path }
        shownPath = shown
        var items: [Crumb] = []
        if p == nil { items.append(Crumb(title: "All Changes", image: NSImage(systemSymbolName: "square.stack", accessibilityDescription: nil), action: #selector(overviewClicked), tag: 0)) }
        if let shown {
            let comps = shown.split(separator: "/").map(String.init)
            for (i, c) in comps.enumerated() {
                items.append(Crumb(title: c, image: i == comps.count - 1 ? fileIcon(shown) : nil, action: #selector(crumbClicked(_:)), tag: i))
            }
        }
        showCrumbs(items)
        toolTip = shown
        let addDel: (Int, Int)
        if p == nil {
            addDel = files.reduce((0, 0)) { ($0.0 + $1.diff.additions, $0.1 + $1.diff.deletions) }
        } else {
            addDel = files.first.map { ($0.diff.additions, $0.diff.deletions) } ?? (0, 0)
        }
        let s = NSMutableAttributedString(string: "+\(addDel.0)", attributes: [.foregroundColor: style.theme.color("success")])
        s.append(NSAttributedString(string: "  −\(addDel.1)", attributes: [.foregroundColor: style.theme.color("danger")]))
        stats.attributedStringValue = s
        stats.isHidden = !files.contains(where: \.isChange)
        reviewedButton.isHidden = reviewable == nil
        let reviewed = reviewable?.reviewed == true
        reviewedButton.image = NSImage(systemSymbolName: reviewed ? "checkmark.circle.fill" : "checkmark.circle", accessibilityDescription: nil)
        reviewedButton.contentTintColor = reviewed ? style.theme.color("success") : .secondaryLabelColor
        reviewedButton.toolTip = reviewed ? "Mark as Not Reviewed (R)" : "Mark as Reviewed (R)"
        reviewedButton.setAccessibilityLabel(reviewedButton.toolTip)
        definitions = p == nil ? [] : files.first?.definitions ?? []
        symbolMenuIsCurrent = false
        symbols.isHidden = true
        symbolChevron.isHidden = true
    }

    private struct Crumb {
        var title: String
        var image: NSImage?
        var action: Selector
        var tag: Int
    }

    private var buttons: [NSButton] = []
    private var separators: [NSImageView] = []

    /// Shows crumbs separated by chevrons, reusing the views already made, since making controls
    /// costs more than changing them.
    private func showCrumbs(_ items: [Crumb]) {
        while buttons.count < items.count { buttons.append(makeCrumb()) }
        while separators.count < items.count - 1 { separators.append(makeSeparator()) }
        var views: [NSView] = []
        for (i, item) in items.enumerated() {
            if i > 0 { views.append(separators[i - 1]) }
            let b = buttons[i]
            if b.title != item.title { b.title = item.title }
            if b.image !== item.image {
                b.image = item.image
                b.imagePosition = item.image == nil ? .noImage : .imageLeading
            }
            b.action = item.action
            b.tag = item.tag
            views.append(b)
        }
        guard crumbs.arrangedSubviews != views else { return }
        for v in crumbs.arrangedSubviews where !views.contains(v) { v.removeFromSuperview() }
        for (i, v) in views.enumerated() where i >= crumbs.arrangedSubviews.count || crumbs.arrangedSubviews[i] !== v {
            crumbs.insertArrangedSubview(v, at: i)
        }
        for v in views { crumbs.setCustomSpacing(3, after: v) }
    }

    private func makeCrumb() -> NSButton {
        let b = NSButton(title: "", target: self, action: nil)
        b.isBordered = false
        b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        b.controlSize = .small
        b.imagePosition = .noImage
        b.imageHugsTitle = true
        b.contentTintColor = crumbColor
        b.lineBreakMode = .byTruncatingMiddle
        b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return b
    }

    private func makeSeparator() -> NSImageView {
        let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.compact.right", accessibilityDescription: nil)!)
        chevron.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        return chevron
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
        guard !definitions.isEmpty else { NSSound.beep(); return }
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
