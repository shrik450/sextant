import AppKit
import RevueCore

/// One thing the jump bar can go to.
struct JumpItem {
    enum Target {
        case file(String)
        /// A 1-based line of a file.
        case line(path: String, line: Int)
        case command(NSMenuItem)
    }

    var target: Target
    var title: String
    var detail: String
    var image: NSImage?
}

/// A bar over the window to type where to go: a file, a definition, a line or a command.
///
/// It shows what its owner finds for the text as it's typed. Return goes to the chosen
/// result, and Command-Return opens it beside the code instead.
@MainActor
final class JumpPanel: NSPanel, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let field = NSTextField()
    let table = NSTableView()
    private let scroll = NSScrollView()
    private let status = NSTextField(labelWithString: "")
    private(set) var items: [JumpItem] = []
    private var searching: Task<Void, Never>?
    /// Finds what the text names, best first.
    var find: ((String) async -> [JumpItem])?
    /// Says what's still being found, such as definitions being indexed.
    var progress: (() -> String?)?
    /// Goes to a result, beside the code when the flag is set.
    var onChoose: ((JumpItem, Bool) -> Void)?

    static let width: CGFloat = 640
    static let rowHeight: CGFloat = 30
    static let visibleRows = 12

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 60), styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        isFloatingPanel = true
        hidesOnDeactivate = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        let back = NSVisualEffectView()
        back.material = .popover
        back.state = .active
        back.wantsLayer = true
        back.layer?.cornerRadius = 12
        back.layer?.masksToBounds = true
        field.font = .systemFont(ofSize: 20, weight: .light)
        field.placeholderString = "Go to a file or definition, > for commands, : for a line, @ in this file"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.cell?.isScrollable = true
        let column = NSTableColumn(identifier: .init("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(clicked)
        table.action = #selector(clicked)
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        for v in [field, scroll, status] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            back.addSubview(v)
        }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: back.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: back.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: back.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: back.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: back.trailingAnchor, constant: -6),
            status.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 4),
            status.leadingAnchor.constraint(equalTo: back.leadingAnchor, constant: 16),
            status.trailingAnchor.constraint(equalTo: back.trailingAnchor, constant: -16),
            status.bottomAnchor.constraint(equalTo: back.bottomAnchor, constant: -8),
        ])
        contentView = back
    }

    override var canBecomeKey: Bool { true }

    /// Shows the bar near the top of a window, empty, and lists what an empty query finds.
    func show(over parent: NSWindow, text: String = "") {
        field.stringValue = text
        let f = parent.frame
        setFrameTopLeftPoint(NSPoint(x: f.midX - Self.width / 2, y: f.maxY - f.height * 0.16))
        if self.parent !== parent {
            self.parent?.removeChildWindow(self)
            parent.addChildWindow(self, ordered: .above)
        }
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.utf16.count, length: 0)
        search()
    }

    func dismiss() {
        searching?.cancel()
        parent?.removeChildWindow(self)
        orderOut(nil)
    }

    override func resignKey() {
        super.resignKey()
        if isVisible { dismiss() }
    }

    /// Finds results for the text, keeping only the latest search's.
    func search() {
        searching?.cancel()
        let text = field.stringValue
        searching = Task { [weak self] in
            guard let found = await self?.find?(text), !Task.isCancelled, let self, self.field.stringValue == text else { return }
            self.show(found)
        }
    }

    /// Refreshes the progress line, and the results once more has been found.
    func progressChanged(foundMore: Bool) {
        status.stringValue = progress?() ?? ""
        if foundMore { search() }
    }

    private func show(_ found: [JumpItem]) {
        items = found
        table.reloadData()
        if !items.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        table.scrollRowToVisible(0)
        status.stringValue = progress?() ?? (items.isEmpty && !field.stringValue.isEmpty ? "Nothing matches" : "")
        let rows = CGFloat(min(items.count, Self.visibleRows))
        let height = 14 + field.intrinsicContentSize.height + 10 + rows * Self.rowHeight + 4 + 16 + 8
        let top = frame.maxY
        setFrame(NSRect(x: frame.minX, y: top - height, width: Self.width, height: height), display: true)
    }

    func controlTextDidChange(_ obj: Notification) { search() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.insertNewline(_:)): choose(beside: false)
        case #selector(NSResponder.cancelOperation(_:)): dismiss()
        default: return false
        }
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isCommandReturn(event) {
            choose(beside: true)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, isCommandReturn(event) {
            choose(beside: true)
            return
        }
        super.sendEvent(event)
    }

    private func isCommandReturn(_ event: NSEvent) -> Bool {
        event.keyCode == 36 && event.modifierFlags.contains(.command)
    }

    private func move(_ by: Int) {
        guard !items.isEmpty else { return }
        let next = max(0, min(items.count - 1, table.selectedRow + by))
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    /// Goes to the selected result.
    func choose(beside: Bool) {
        guard items.indices.contains(table.selectedRow) else { NSSound.beep(); return }
        let item = items[table.selectedRow]
        dismiss()
        onChoose?(item, beside)
    }

    @objc private func clicked() {
        guard table.clickedRow >= 0 else { return }
        table.selectRowIndexes([table.clickedRow], byExtendingSelection: false)
        choose(beside: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: JumpCell.id, owner: nil) as? JumpCell) ?? JumpCell()
        cell.show(items[row])
        return cell
    }
}

/// A result in the jump bar: its icon, what it is, and where.
@MainActor
final class JumpCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("JumpCell")
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingHead
        icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        for v in [icon, title, detail] { addSubview(v) }
        textField = title
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ item: JumpItem) {
        icon.image = item.image
        title.stringValue = item.title
        detail.stringValue = item.detail
        needsLayout = true
    }

    /// Lays out by frame: the icon, the title at its own width, and the detail after it.
    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: 10, y: round((h - 16) / 2), width: 16, height: 16)
        let th = title.intrinsicContentSize.height
        let titleWidth = min(ceil(title.attributedStringValue.size().width) + 4, bounds.width * 0.55)
        title.frame = NSRect(x: 34, y: round((h - th) / 2), width: titleWidth, height: th)
        let dh = detail.intrinsicContentSize.height
        let x = title.frame.maxX + 10
        detail.frame = NSRect(x: x, y: round((h - dh) / 2), width: max(0, bounds.width - x - 10), height: dh)
    }
}
