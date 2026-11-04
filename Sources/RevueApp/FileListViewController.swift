import AppKit
import RevueCore

@MainActor
protocol FileListDelegate: AnyObject {
    func fileListSelected(_ file: Int)
    func fileListSelectedOverview()
    func fileListToggleReviewed(_ files: [Int])
    func fileListContextMenu(_ files: [Int]) -> NSMenu?
}

/// The list of changes in the current target, with their review state.
@MainActor
final class FileListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    enum Current: Equatable { case none, overview, file(Int) }

    weak var delegate: FileListDelegate?
    let table = KeyTableView()
    let scroll = NSScrollView()
    let filter = NSSearchField()
    let progressLabel = NSTextField(labelWithString: "")
    /// What's being reviewed, as the commit message or the commits in a range.
    let header = NSTextField(wrappingLabelWithString: "")
    private var headerFull = false
    private var headerText = NSAttributedString()

    private var files: [FileState] = []
    /// The indices into `files` that pass the filter.
    private var shown: [Int] = []
    private var suppressSelectionCallback = false
    private var current: Current = .none

    override func loadView() {
        let v = NSView()
        let col = NSTableColumn(identifier: .init("file"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.style = .inset
        table.rowHeight = 26
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.menu = NSMenu()
        table.menu?.delegate = self
        table.onSpace = { [weak self] in self?.toggleSelected() }
        table.setAccessibilityLabel("Changes")

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        header.isSelectable = true
        header.maximumNumberOfLines = 4
        header.lineBreakMode = .byTruncatingTail
        header.cell?.truncatesLastVisibleLine = true
        header.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        header.translatesAutoresizingMaskIntoConstraints = false
        header.isHidden = true
        header.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(toggleHeader)))

        filter.placeholderString = "Filter"
        filter.delegate = self
        filter.controlSize = .regular
        filter.sendsSearchStringImmediately = true
        filter.translatesAutoresizingMaskIntoConstraints = false
        filter.target = self
        filter.action = #selector(filterChanged)

        progressLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        progressLabel.alignment = .right
        progressLabel.setContentHuggingPriority(.required, for: .horizontal)

        v.addSubview(header)
        v.addSubview(scroll)
        v.addSubview(filter)
        v.addSubview(progressLabel)
        let headerGap = scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6)
        let noHeader = scroll.topAnchor.constraint(equalTo: v.topAnchor)
        noHeader.priority = .defaultHigh
        headerGap.priority = .defaultHigh + 1
        self.headerGap = headerGap
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: v.topAnchor, constant: 2),
            header.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),
            noHeader, headerGap,
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: filter.topAnchor, constant: -8),
            filter.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            filter.trailingAnchor.constraint(equalTo: progressLabel.leadingAnchor, constant: -8),
            progressLabel.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),
            progressLabel.centerYAnchor.constraint(equalTo: filter.centerYAnchor),
            filter.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -10),
        ])
        view = v
    }

    private var headerGap: NSLayoutConstraint?

    /// Shows the commit message, with its first line emphasised, or a range's commits.
    func setHeader(detail: CommitDetail?, commits: [Commit]) {
        let s = NSMutableAttributedString()
        let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor]
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]
        if let d = detail {
            let parts = d.message.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            s.append(NSAttributedString(string: parts.first.map(String.init) ?? "", attributes: title))
            let rest = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            if !rest.isEmpty { s.append(NSAttributedString(string: "\n" + rest, attributes: body)) }
        } else if commits.count > 1 {
            s.append(NSAttributedString(string: "\(commits.count) commits", attributes: title))
            for c in commits.prefix(30) { s.append(NSAttributedString(string: "\n\(c.shortOid)  \(c.subject)", attributes: body)) }
            if commits.count > 30 { s.append(NSAttributedString(string: "\n…", attributes: body)) }
        } else if let c = commits.first {
            s.append(NSAttributedString(string: c.subject, attributes: title))
        }
        headerText = s
        header.attributedStringValue = s
        header.toolTip = s.length > 0 ? s.string : nil
        header.isHidden = s.length == 0
        headerGap?.isActive = s.length > 0
        headerFull = false
        header.maximumNumberOfLines = 4
    }

    @objc private func toggleHeader() {
        headerFull.toggle()
        header.maximumNumberOfLines = headerFull ? 0 : 4
        header.attributedStringValue = headerText
    }

    func setFiles(_ f: [FileState]) {
        files = f
        applyFilter()
    }

    func refreshReviewState() {
        table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<table.numberOfRows), columnIndexes: [0])
        updateProgress()
    }

    private func updateProgress() {
        let changes = files.filter(\.isChange)
        let done = changes.filter(\.reviewed).count
        progressLabel.stringValue = changes.isEmpty ? "" : "\(done)/\(changes.count)"
        progressLabel.textColor = done == changes.count && !changes.isEmpty ? NSColor.systemGreen : .secondaryLabelColor
        progressLabel.toolTip = "\(done) of \(changes.count) files reviewed"
    }

    /// Whether the "All Changes" row leads the list, which it does when nothing filters it.
    private var hasAllRow: Bool { files.count > 1 && filter.stringValue.trimmingCharacters(in: .whitespaces).isEmpty }
    private var offset: Int { hasAllRow ? 1 : 0 }
    private func file(atRow r: Int) -> Int? { r - offset >= 0 && r - offset < shown.count ? shown[r - offset] : nil }
    private func row(ofFile f: Int) -> Int? { shown.firstIndex(of: f).map { $0 + offset } }

    private func applyFilter() {
        let q = filter.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let selected = selectedFiles
        if q.isEmpty {
            shown = Array(files.indices)
        } else {
            let ranked = rankFuzzy(q, files.map(\.path))
            let index = Dictionary(files.indices.map { (files[$0].path, $0) }, uniquingKeysWith: { a, _ in a })
            shown = ranked.compactMap { index[$0] }
        }
        suppressSelectionCallback = true
        table.reloadData()
        var rows = IndexSet(selected.compactMap { row(ofFile: $0) })
        if rows.isEmpty {
            switch current {
            case .file(let c): if let r = row(ofFile: c) { rows = [r] }
            case .overview: if hasAllRow { rows = [0] }
            case .none: break
            }
        }
        table.selectRowIndexes(rows, byExtendingSelection: false)
        suppressSelectionCallback = false
        updateProgress()
    }

    @objc private func filterChanged() { applyFilter() }

    func controlTextDidChange(_ obj: Notification) { applyFilter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) || sel == #selector(NSResponder.moveDown(_:)) {
            view.window?.makeFirstResponder(table)
            if table.selectedRow < 0, table.numberOfRows > 0 { table.selectRowIndexes([0], byExtendingSelection: false) }
            return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            if filter.stringValue.isEmpty { view.window?.makeFirstResponder(table) } else { filter.stringValue = ""; applyFilter() }
            return true
        }
        return false
    }

    var selectedFiles: [Int] { table.selectedRowIndexes.compactMap { file(atRow: $0) } }

    /// Highlights what the reader shows, without telling the delegate.
    func showCurrent(_ c: Current) {
        current = c
        let r: Int? = switch c {
        case .file(let f): row(ofFile: f)
        case .overview: hasAllRow ? 0 : nil
        case .none: nil
        }
        suppressSelectionCallback = true
        defer { suppressSelectionCallback = false }
        guard let r else { table.deselectAll(nil); return }
        if table.selectedRowIndexes == [r] { return }
        table.selectRowIndexes([r], byExtendingSelection: false)
        table.scrollRowToVisible(r)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count + offset }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let fi = file(atRow: row) else {
            let id = NSUserInterfaceItemIdentifier("AllCell")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
                let c = NSTableCellView()
                c.identifier = id
                let img = NSImageView(image: NSImage(systemSymbolName: "square.stack", accessibilityDescription: nil)!)
                img.contentTintColor = .secondaryLabelColor
                let tf = NSTextField(labelWithString: "All Changes")
                for v in [img, tf] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; c.addSubview(v) }
                c.textField = tf
                NSLayoutConstraint.activate([
                    img.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 3),
                    img.widthAnchor.constraint(equalToConstant: 16),
                    img.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                    tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 28),
                    tf.trailingAnchor.constraint(lessThanOrEqualTo: c.trailingAnchor, constant: -4),
                    tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                return c
            }()
            return cell
        }
        let cell = (tableView.makeView(withIdentifier: FileCell.id, owner: nil) as? FileCell) ?? FileCell()
        cell.configure(files[fi])
        cell.onToggle = { [weak self] in self?.delegate?.fileListToggleReviewed([fi]) }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionCallback, table.selectedRowIndexes.count == 1 else { return }
        if let f = selectedFiles.first { delegate?.fileListSelected(f) } else if hasAllRow, table.selectedRow == 0 { delegate?.fileListSelectedOverview() }
    }

    @objc private func doubleClicked() {
        let r = table.clickedRow
        if let f = file(atRow: r) { delegate?.fileListSelected(f) } else if r == 0, hasAllRow { delegate?.fileListSelectedOverview() }
    }

    func toggleSelected() {
        let sel = selectedFiles
        if !sel.isEmpty { delegate?.fileListToggleReviewed(sel) }
    }
}

extension FileListViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        var targets = selectedFiles
        let clicked = table.clickedRow
        if clicked >= 0, !table.selectedRowIndexes.contains(clicked) { targets = file(atRow: clicked).map { [$0] } ?? [] }
        guard !targets.isEmpty, let m = delegate?.fileListContextMenu(targets) else { return }
        for item in m.items { m.removeItem(item); menu.addItem(item) }
    }
}

/// A table view that reports space and delete presses and lets bare-key menu shortcuts through.
final class KeyTableView: NSTableView {
    var onSpace: (() -> Void)?
    var onDelete: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        if plain, event.charactersIgnoringModifiers == " ", let onSpace { onSpace(); return }
        if plain, let onDelete, event.keyCode == 51 || event.keyCode == 117 { onDelete(); return }
        super.keyDown(with: event)
    }
}

@MainActor
final class FileCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("FileCell")
    let check = NSButton()
    let name = NSTextField(labelWithString: "")
    let dir = NSTextField(labelWithString: "")
    let status = NSTextField(labelWithString: "")
    var onToggle: (() -> Void)?

    init() {
        super.init(frame: .zero)
        identifier = FileCell.id
        check.isBordered = false
        check.imagePosition = .imageOnly
        check.target = self
        check.action = #selector(toggle)
        check.setButtonType(.momentaryChange)
        name.lineBreakMode = .byTruncatingMiddle
        name.font = .systemFont(ofSize: 13)
        dir.lineBreakMode = .byTruncatingHead
        dir.font = .systemFont(ofSize: 11)
        dir.textColor = .secondaryLabelColor
        status.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        status.alignment = .center
        for v in [check, name, dir, status] as [NSView] { addSubview(v) }
        textField = name
    }

    /// Lays out the file name and directory by hand.
    ///
    /// The file name always gets the space it needs first; the directory only shows when a
    /// meaningful amount of it fits.
    override func layout() {
        super.layout()
        let h = bounds.height
        check.frame = NSRect(x: 2, y: (h - 18) / 2, width: 18, height: 18)
        let sw: CGFloat = 16
        status.sizeToFit()
        status.frame = NSRect(x: bounds.width - 4 - sw, y: (h - status.frame.height) / 2, width: sw, height: status.frame.height)
        let x0: CGFloat = 28
        let right = status.frame.minX - 6
        name.sizeToFit()
        let nameW = min(name.frame.width, max(0, right - x0))
        name.frame = NSRect(x: x0, y: (h - name.frame.height) / 2, width: nameW, height: name.frame.height)
        dir.sizeToFit()
        let dirX = name.frame.maxX + 6
        let dirW = min(dir.frame.width, right - dirX)
        dir.isHidden = dir.stringValue.isEmpty || dirW < min(dir.frame.width, 48)
        let nameBaseline = name.frame.minY + name.baselineOffsetFromBottom
        dir.frame = NSRect(x: dirX, y: nameBaseline - dir.baselineOffsetFromBottom, width: max(0, dirW), height: dir.frame.height)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggle() { onToggle?() }

    func configure(_ f: FileState) {
        let path = f.path as NSString
        name.stringValue = path.lastPathComponent
        dir.stringValue = path.deletingLastPathComponent
        needsLayout = true
        toolTip = f.diff.change.isRename ? "\(f.diff.change.oldPath) → \(f.path)" : f.path
        let reviewed = f.reviewed
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        if reviewed {
            check.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Reviewed")?
                .withSymbolConfiguration(cfg.applying(.init(paletteColors: [.white, .controlAccentColor])))
        } else {
            check.image = NSImage(systemSymbolName: "circle", accessibilityDescription: "Not reviewed")?
                .withSymbolConfiguration(cfg.applying(.init(paletteColors: [.tertiaryLabelColor])))
        }
        check.setAccessibilityLabel(reviewed ? "Mark as not reviewed" : "Mark as reviewed")
        name.textColor = reviewed ? .secondaryLabelColor : .labelColor
        var (letter, color) = statusLetter(f.diff.change.status)
        if f.conflicted { (letter, color) = ("!", .systemRed) }
        status.stringValue = letter
        status.textColor = reviewed ? .tertiaryLabelColor : color
        status.toolTip = switch letter {
        case "A": "Added"; case "U": "Untracked"; case "D": "Deleted"; case "R": "Renamed"; case "C": "Copied"
        case "T": "Type changed"; case "!": "Conflicted"; default: "Modified"
        }
    }
}
