import AppKit

@MainActor
protocol NotesPaneDelegate: AnyObject {
    func notesPaneOpen(_ note: Note)
    func notesPaneEdit(_ note: Note, relativeTo rect: NSRect, of view: NSView)
    func notesPaneDelete(_ ids: Set<UUID>)
    func notesPaneCopy(_ notes: [Note]?)
    func notesPaneAddOnLines()
    func notesPaneAddOnReview()
}

/// The review's notes, under the inspector, building up as the review goes.
///
/// Selecting a note on lines goes to it, Return or a double click edits it, and Copy All hands
/// every note on as Markdown.
@MainActor
final class NotesPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    weak var delegate: NotesPaneDelegate?
    let table = KeyTableView()
    private let count = NSTextField(labelWithString: "")
    private let add = NSButton()
    private let copyAll = NSButton()
    private let empty = EmptyState(symbolSize: 22, font: .detail)
    private(set) var notes: [Note] = []

    override func loadView() {
        let v = NSView()
        let title = NSTextField(labelWithString: "Notes")
        title.font = .sectionLabel
        title.textColor = .themed("fgMuted")
        count.font = .detailDigits
        count.textColor = .themed("fgSubtle")
        for (b, symbol, tip, action) in [(add, "plus", "Add a Note", #selector(showAddMenu(_:))), (copyAll, "doc.on.doc", "Copy All Notes as Markdown", #selector(copyAllNotes))] {
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            b.isBordered = false
            b.bezelStyle = .accessoryBarAction
            b.toolTip = tip
            b.target = self
            b.action = action
            b.symbolConfiguration = .init(textStyle: .body, scale: .small)
            b.contentTintColor = .themed("fgMuted")
        }
        let header = NSStackView(views: [title, count, NSView(), add, copyAll])
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 10)

        let col = NSTableColumn(identifier: .init("n"))
        table.addTableColumn(col)
        table.headerView = nil
        table.style = .sourceList
        table.backgroundColor = .clear
        table.usesAutomaticRowHeights = true
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(editClicked)
        table.onDelete = { [weak self] in self?.deleteSelected() }
        table.onReturn = { [weak self] in self?.editSelected() }
        table.setAccessibilityLabel("Notes")
        table.menu = NSMenu()
        table.menu?.addItem(withTitle: "Edit Note", action: #selector(editClicked), keyEquivalent: "").target = self
        table.menu?.addItem(withTitle: "Copy as Markdown", action: #selector(copySelected), keyEquivalent: "").target = self
        table.menu?.addItem(.separator())
        table.menu?.addItem(withTitle: "Delete", action: #selector(deleteSelected), keyEquivalent: "").target = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        empty.show("Select lines and press C, or click + beside a line number. Press ⇧C for a note on the whole review.", symbol: "note.text")
        for x in [header, scroll, empty] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: v.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 24),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            empty.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 18),
            empty.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -18),
        ])
        view = v
        setNotes([])
    }

    func setNotes(_ n: [Note]) {
        let selected = Set(selection.map(\.id))
        notes = n
        table.reloadData()
        table.selectRowIndexes(IndexSet(notes.indices.filter { selected.contains(notes[$0].id) }), byExtendingSelection: false)
        empty.isHidden = !notes.isEmpty
        count.stringValue = notes.isEmpty ? "" : "\(notes.count)"
        copyAll.isEnabled = !notes.isEmpty
    }

    func numberOfRows(in tableView: NSTableView) -> Int { notes.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: NoteCell.id, owner: nil) as? NoteCell) ?? NoteCell()
        let n = notes[row]
        cell.title.stringValue = n.lines.map { lineReference(path: ($0.path as NSString).lastPathComponent, lines: $0.range, old: $0.old) } ?? n.title
        cell.title.font = n.lines == nil ? .systemFont(ofSize: NSFont.detail.pointSize, weight: .semibold) : .detailCode
        cell.body.stringValue = n.text
        cell.toolTip = n.title
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.window?.firstResponder === table, table.selectedRowIndexes.count == 1, let n = selection.first, n.lines != nil else { return }
        delegate?.notesPaneOpen(n)
    }

    /// The notes a command acts on: the clicked one, else the selected ones.
    private var selection: [Note] {
        let rows = table.clickedRow >= 0 && !table.selectedRowIndexes.contains(table.clickedRow) ? IndexSet(integer: table.clickedRow) : table.selectedRowIndexes
        return rows.compactMap { $0 < notes.count ? notes[$0] : nil }
    }

    private func edit(row: Int) {
        guard notes.indices.contains(row) else { return }
        table.scrollRowToVisible(row)
        delegate?.notesPaneEdit(notes[row], relativeTo: table.rect(ofRow: row), of: table)
    }

    /// Opens the editor for a note, if the pane lists it.
    func edit(_ id: UUID) {
        guard let row = notes.firstIndex(where: { $0.id == id }) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        edit(row: row)
    }

    @objc private func editClicked() { edit(row: table.clickedRow >= 0 ? table.clickedRow : table.selectedRow) }
    private func editSelected() { edit(row: table.selectedRow) }
    @objc private func copyAllNotes() { delegate?.notesPaneCopy(nil) }
    @objc private func copySelected() { delegate?.notesPaneCopy(selection) }

    @objc private func deleteSelected() {
        let ids = Set(selection.map(\.id))
        if !ids.isEmpty { delegate?.notesPaneDelete(ids) }
    }

    @objc private func showAddMenu(_ sender: NSButton) {
        let m = NSMenu()
        m.addItem(withTitle: "Note on Selected Lines", action: #selector(addOnLines), keyEquivalent: "c").target = self
        m.items.last?.keyEquivalentModifierMask = []
        m.addItem(withTitle: "Note on Whole Review", action: #selector(addOnReview), keyEquivalent: "C").target = self
        m.items.last?.keyEquivalentModifierMask = [.shift]
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func addOnLines() { delegate?.notesPaneAddOnLines() }
    @objc private func addOnReview() { delegate?.notesPaneAddOnReview() }
}

@MainActor
private final class NoteCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("NoteCell")
    let title = NSTextField(labelWithString: "")
    let body = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = NoteCell.id
        title.textColor = .themed("fgMuted")
        title.lineBreakMode = .byTruncatingHead
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        body.font = .row
        body.maximumNumberOfLines = 4
        body.lineBreakMode = .byTruncatingTail
        body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for v in [title, body] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        textField = body
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            body.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        body.preferredMaxLayoutWidth = max(60, bounds.width - 8)
    }
}
