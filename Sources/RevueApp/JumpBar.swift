import AppKit
import RevueCore

/// The bar above the code: where you are, as folders, file and definition, and the size of the
/// change.
///
/// Each folder or file opens a menu of what sits beside it in the snapshot, like Xcode's jump bar.
@MainActor
final class JumpBar: NSView, NSMenuDelegate {
    private let crumbs = NSStackView()
    let symbols = NSPopUpButton(frame: .zero, pullsDown: true)
    private let symbolChevron = NSImageView(image: NSImage(systemSymbolName: "chevron.compact.right", accessibilityDescription: nil)!)
    let stats = NSTextField(labelWithString: "")
    /// Every file in the snapshot, sorted, for the folder menus.
    var tree: [String] = []
    private(set) var currentFile: Int?
    private(set) var definitions: [Symbol] = []
    private var shownPath: String?
    private var shownKey = ""
    var onOpenPath: ((String) -> Void)?
    var onShowOverview: (() -> Void)?
    var onSelectSymbol: ((Symbol) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        crumbs.orientation = .horizontal
        crumbs.spacing = 0
        crumbs.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        symbols.isBordered = false
        symbols.controlSize = .small
        symbols.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        (symbols.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        symbols.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        symbols.isHidden = true
        symbolChevron.isHidden = true
        stats.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        stats.setContentCompressionResistancePriority(.required, for: .horizontal)
        stats.setContentHuggingPriority(.required, for: .horizontal)
        symbolChevron.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        symbolChevron.contentTintColor = .tertiaryLabelColor
        symbolChevron.isHidden = true
        let row = NSStackView(views: [crumbs, symbolChevron, symbols, NSView(), stats])
        row.orientation = .horizontal
        row.spacing = 0
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
        let key = "\(p ?? "\u{0}")|\(current ?? -1)|\(files.map { "\(ObjectIdentifier($0).hashValue):\($0.lines.count)" })|\(style.theme.name)|\(style.theme.color("success"))|\(style.theme.color("danger"))"
        guard key != shownKey else { return }
        shownKey = key
        currentFile = current
        let shown = p ?? current.map { files[$0].path }
        shownPath = shown
        crumbs.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if p == nil { addCrumb("All Changes", image: NSImage(systemSymbolName: "square.stack", accessibilityDescription: nil), action: #selector(overviewClicked)) }
        if let shown {
            let comps = shown.split(separator: "/").map(String.init)
            for (i, c) in comps.enumerated() {
                if !crumbs.arrangedSubviews.isEmpty { addSeparator() }
                let isFile = i == comps.count - 1
                let b = addCrumb(c, image: isFile ? fileIcon(shown) : nil, action: #selector(crumbClicked(_:)))
                b.tag = i
            }
        }
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
        if p != nil, let f = files.first, let lang = f.language, lang.hasTags {
            definitions = lang.symbols(f.sideText(old: false).joined(separator: "\n")).filter(\.isDefinition)
            rebuildSymbolMenu()
        } else {
            definitions = []
        }
        symbols.isHidden = true
        symbolChevron.isHidden = true
    }

    @discardableResult
    private func addCrumb(_ title: String, image: NSImage?, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.isBordered = false
        b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        b.controlSize = .small
        b.image = image
        b.imagePosition = image == nil ? .noImage : .imageLeading
        b.imageHugsTitle = true
        b.contentTintColor = .labelColor
        b.lineBreakMode = .byTruncatingMiddle
        b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        crumbs.addArrangedSubview(b)
        return b
    }

    private func addSeparator() {
        let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.compact.right", accessibilityDescription: nil)!)
        chevron.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        crumbs.addArrangedSubview(chevron)
        crumbs.setCustomSpacing(3, after: crumbs.arrangedSubviews[crumbs.arrangedSubviews.count - 2])
        crumbs.setCustomSpacing(3, after: chevron)
    }

    private func rebuildSymbolMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        for (i, d) in definitions.enumerated() {
            let depth = definitions[..<i].filter { $0.range.location <= d.range.location && NSMaxRange($0.range) >= NSMaxRange(d.range) }.count
            let item = menu.addItem(withTitle: d.name, action: #selector(symbolChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.indentationLevel = min(depth, 6)
            item.image = NSImage(systemSymbolName: symbolImage(d.kind), accessibilityDescription: d.kind)
        }
        symbols.menu = menu
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
        symbols.menu?.item(at: 0)?.image = NSImage(systemSymbolName: symbolImage(enclosing.kind), accessibilityDescription: nil)
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

    /// Fills a folder's menu with the folders and files directly inside it.
    func menuNeedsUpdate(_ menu: NSMenu) {
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
