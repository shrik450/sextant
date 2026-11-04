import AppKit
import RevueCore

@MainActor
protocol SidebarDelegate: AnyObject {
    func sidebarSelected(_ target: Target?)
    func sidebarLoadMore()
    func sidebarContextMenu(for target: Target) -> NSMenu?
}

enum SidebarItem: Equatable {
    case section(String)
    case target(Target, title: String, symbol: String, count: Int, tooltip: String?)
    case commit(Int)
    case stash(Int)
    case message(String)
}

@MainActor
final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    weak var delegate: SidebarDelegate?
    var repo: Repo!
    let table = KeyTableView()
    let scroll = NSScrollView()
    let filter = NSSearchField()
    private(set) var items: [SidebarItem] = []
    private var suppress = false

    override func loadView() {
        let v = NSView()
        let col = NSTableColumn(identifier: .init("main"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.style = .sourceList
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        table.floatsGroupRows = false
        table.menu = NSMenu()
        table.menu?.delegate = self
        table.setAccessibilityLabel("History")
        table.usesAutomaticRowHeights = false

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)

        filter.placeholderString = "Filter"
        filter.delegate = self
        filter.sendsSearchStringImmediately = true
        filter.translatesAutoresizingMaskIntoConstraints = false
        filter.target = self
        filter.action = #selector(filterChanged)

        v.addSubview(scroll)
        v.addSubview(filter)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: v.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: filter.topAnchor, constant: -8),
            filter.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            filter.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),
            filter.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -10),
        ])
        view = v
        NotificationCenter.default.addObserver(self, selector: #selector(reviewsChanged), name: ReviewStore.didChange, object: nil)
    }

    @objc private func reviewsChanged() {
        let rows = IndexSet(items.indices.filter { if case .commit = items[$0] { return true }; return false })
        table.reloadData(forRowIndexes: rows, columnIndexes: [0])
    }

    @objc private func filterChanged() { reload(preserving: currentTarget) }
    func controlTextDidChange(_ obj: Notification) { reload(preserving: currentTarget) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) || sel == #selector(NSResponder.moveDown(_:)) {
            view.window?.makeFirstResponder(table)
            let filtering = !filter.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
            if filtering || table.selectedRow < 0, let first = items.firstIndex(where: { if case .commit = $0 { return true }; return false }) {
                table.selectRowIndexes([first], byExtendingSelection: false)
                table.scrollRowToVisible(first)
            }
            return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            if filter.stringValue.isEmpty { view.window?.makeFirstResponder(table) } else { filter.stringValue = ""; reload(preserving: currentTarget) }
            return true
        }
        return false
    }

    @objc private func scrolled() {
        guard repo.hasMoreCommits, filter.stringValue.isEmpty else { return }
        let visible = table.rows(in: table.visibleRect)
        if visible.location + visible.length >= items.count - 20 { delegate?.sidebarLoadMore() }
    }

    /// Rebuilds rows from the repo, then reselects `target` if it's still present.
    func reload(preserving target: Target?) {
        var out: [SidebarItem] = []
        let s = repo.status
        out.append(.section("Changes"))
        out.append(.target(.uncommitted, title: "Uncommitted", symbol: "pencil.and.list.clipboard", count: s.uncommitted, tooltip: nil))
        if s.staged > 0 { out.append(.target(.staged, title: "Staged", symbol: "tray.full", count: s.staged, tooltip: nil)) }
        if s.unstaged > 0 && s.staged > 0 { out.append(.target(.unstaged, title: "Unstaged", symbol: "tray", count: s.unstaged, tooltip: nil)) }
        if let base = repo.branchBase, let head = repo.head, let d = repo.defaultBranch {
            let name = repo.branch ?? String(head.prefix(7))
            out.append(.target(.range(base: base, head: head, label: "\(d)...\(name)"), title: name, symbol: "arrow.triangle.branch", count: repo.aheadCount, tooltip: "Everything on \(name) since it diverged from \(d)"))
        }

        let q = filter.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        out.append(.section("History"))
        var any = false
        for (i, c) in repo.commits.enumerated() {
            if q.isEmpty || c.subject.lowercased().contains(q) || c.author.lowercased().contains(q) || c.oid.hasPrefix(q) || c.refs.contains(where: { $0.lowercased().contains(q) }) {
                out.append(.commit(i))
                any = true
            }
        }
        if !any { out.append(.message(repo.head == nil ? "No commits yet" : "No matches")) }
        if !repo.stashes.isEmpty {
            out.append(.section("Stashes"))
            for i in repo.stashes.indices { out.append(.stash(i)) }
        }
        let oldItems = items
        items = out
        suppress = true
        if oldItems.count != out.count || oldItems != out {
            table.reloadData()
        } else {
            table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<items.count), columnIndexes: [0])
        }
        select(target, notify: false)
        suppress = false
    }

    func target(of item: SidebarItem) -> Target? {
        switch item {
        case .target(let t, _, _, _, _): t
        case .commit(let i): .commit(repo.commits[i].oid)
        case .stash(let i): .stash(repo.stashes[i].oid)
        default: nil
        }
    }

    /// The target the current selection represents.
    ///
    /// Several selected commits form a range.
    var currentTarget: Target? {
        let rows = table.selectedRowIndexes.filter { $0 < items.count }
        let commitIdx = rows.compactMap { r -> Int? in if case .commit(let i) = items[r] { return i }; return nil }
        if commitIdx.count > 1 {
            let newest = repo.commits[commitIdx.min()!], oldest = repo.commits[commitIdx.max()!]
            let base = oldest.parents.first ?? emptyTreeOid
            return .range(base: base, head: newest.oid, label: "\(oldest.shortOid)^..\(newest.shortOid)")
        }
        guard let r = rows.first else { return nil }
        return target(of: items[r])
    }

    /// Selects the rows for `target`.
    ///
    /// A range of listed commits selects every commit in it.
    func select(_ target: Target?, notify: Bool) {
        suppress = !notify
        defer { suppress = false }
        guard let target else { table.deselectAll(nil); return }
        if let r = items.firstIndex(where: { self.target(of: $0) == target }) {
            table.selectRowIndexes([r], byExtendingSelection: false)
            table.scrollRowToVisible(r)
            return
        }
        if case .range(let base, let head, _) = target,
           let hi = repo.commits.firstIndex(where: { $0.oid == head }),
           let lo = repo.commits.firstIndex(where: { $0.parents.first == base }), lo >= hi {
            let rows = IndexSet(items.indices.filter { if case .commit(let i) = items[$0] { return i >= hi && i <= lo }; return false })
            if rows.count == lo - hi + 1 {
                table.selectRowIndexes(rows, byExtendingSelection: false)
                table.scrollRowToVisible(rows.first!)
                return
            }
        }
        table.deselectAll(nil)
    }

    /// Moves to an older (+1) or newer (-1) commit.
    func step(_ dir: Int) {
        let commitRows = items.indices.filter { if case .commit = items[$0] { return true }; return false }
        guard !commitRows.isEmpty else { NSSound.beep(); return }
        let sel = table.selectedRowIndexes
        let next: Int?
        if let cur = dir > 0 ? sel.last : sel.first, commitRows.contains(cur) {
            next = dir > 0 ? commitRows.first(where: { $0 > cur }) : commitRows.last(where: { $0 < cur })
        } else {
            next = dir > 0 ? commitRows.first : nil
        }
        guard let next else { NSSound.beep(); return }
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .section = items[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch items[row] {
        case .section: 28
        case .commit, .stash: 46
        default: 28
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        switch items[row] {
        case .section, .message: false
        default: true
        }
    }

    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        let commits = proposed.filter { if case .commit = items[$0] { return true }; return false }
        if proposed.count > 1 {
            if commits.count == proposed.count { return proposed }
            let prev = tableView.selectedRowIndexes
            let added = proposed.subtracting(prev)
            return IndexSet(added.first.map { [$0] } ?? [proposed.first!])
        }
        return proposed
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch items[row] {
        case .section(let title):
            let cell = NSTableCellView()
            let l = NSTextField(labelWithString: title)
            l.font = .systemFont(ofSize: 11, weight: .semibold)
            l.textColor = .secondaryLabelColor
            l.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(l)
            cell.textField = l
            NSLayoutConstraint.activate([l.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2), l.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -4)])
            return cell
        case .target(_, let title, let symbol, let count, let tip):
            let cell = (tableView.makeView(withIdentifier: TargetCell.id, owner: nil) as? TargetCell) ?? TargetCell()
            cell.configure(title: title, symbol: symbol, count: count)
            cell.toolTip = tip
            return cell
        case .commit(let i):
            let cell = (tableView.makeView(withIdentifier: CommitCell.id, owner: nil) as? CommitCell) ?? CommitCell()
            let c = repo.commits[i]
            cell.configure(subject: c.subject, sha: c.shortOid, author: c.author, date: c.date, refs: c.refs, progress: repo.reviews.progress(c.changes))
            return cell
        case .stash(let i):
            let cell = (tableView.makeView(withIdentifier: CommitCell.id, owner: nil) as? CommitCell) ?? CommitCell()
            let s = repo.stashes[i]
            cell.configure(subject: s.subject, sha: s.ref, author: nil, date: s.date, refs: [], progress: (0, 0))
            return cell
        case .message(let m):
            let cell = NSTableCellView()
            let l = NSTextField(labelWithString: m)
            l.textColor = .tertiaryLabelColor
            l.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(l)
            NSLayoutConstraint.activate([l.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6), l.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppress else { return }
        delegate?.sidebarSelected(currentTarget)
    }
}

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let r = table.clickedRow
        guard r >= 0, r < items.count else { return }
        var t = target(of: items[r])
        if table.selectedRowIndexes.contains(r), table.selectedRowIndexes.count > 1 { t = currentTarget }
        guard let t, let m = delegate?.sidebarContextMenu(for: t) else { return }
        for item in m.items { m.removeItem(item); menu.addItem(item) }
    }
}

func compactDate(_ d: Date) -> String {
    let s = -d.timeIntervalSinceNow
    if s < 60 { return "now" }
    if s < 3600 { return "\(Int(s / 60))m" }
    if s < 86400 { return "\(Int(s / 3600))h" }
    if s < 86400 * 7 { return "\(Int(s / 86400))d" }
    let cal = Calendar.current
    if cal.component(.year, from: d) == cal.component(.year, from: Date()) {
        return d.formatted(.dateTime.month(.abbreviated).day())
    }
    return d.formatted(.dateTime.year(.twoDigits).month(.twoDigits).day(.twoDigits))
}

@MainActor
final class TargetCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("TargetCell")
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let count = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = TargetCell.id
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        icon.contentTintColor = .controlAccentColor
        title.translatesAutoresizingMaskIntoConstraints = false
        title.lineBreakMode = .byTruncatingTail
        title.font = .systemFont(ofSize: 13)
        count.translatesAutoresizingMaskIntoConstraints = false
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        count.textColor = .secondaryLabelColor
        count.setContentHuggingPriority(.required, for: .horizontal)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(icon); addSubview(title); addSubview(count)
        imageView = icon
        textField = title
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            count.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 6),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title t: String, symbol: String, count n: Int) {
        title.stringValue = t
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        count.stringValue = n > 0 ? "\(n)" : ""
        title.textColor = n > 0 || symbol == "arrow.triangle.branch" ? .labelColor : .secondaryLabelColor
    }
}

/// A small pie showing how much of a commit has been reviewed.
@MainActor
final class ProgressPie: NSView {
    var fraction: CGFloat = 0 { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: 14, height: 14) }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1.5, dy: 1.5)
        let color = NSColor.controlAccentColor
        if fraction >= 1 {
            let img = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Reviewed")?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular).applying(.init(paletteColors: [.white, NSColor.systemGreen])))
            img?.draw(in: bounds)
            return
        }
        color.withAlphaComponent(0.6).setStroke()
        let ring = NSBezierPath(ovalIn: r)
        ring.lineWidth = 1.2
        ring.stroke()
        guard fraction > 0 else { return }
        let c = NSPoint(x: r.midX, y: r.midY)
        let p = NSBezierPath()
        p.move(to: c)
        p.appendArc(withCenter: c, radius: r.width / 2 - 1.5, startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
        p.close()
        color.setFill()
        p.fill()
    }
}

@MainActor
final class CommitCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("CommitCell")
    let subject = NSTextField(labelWithString: "")
    let meta = NSTextField(labelWithString: "")
    let date = NSTextField(labelWithString: "")
    let pie = ProgressPie()

    init() {
        super.init(frame: .zero)
        identifier = CommitCell.id
        for v in [subject, meta, date] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.lineBreakMode = .byTruncatingTail
            v.maximumNumberOfLines = 1
            v.usesSingleLineMode = true
            v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(v)
        }
        subject.font = .systemFont(ofSize: 13)
        meta.font = .systemFont(ofSize: 11)
        date.font = .systemFont(ofSize: 11)
        date.textColor = .secondaryLabelColor
        date.alignment = .right
        date.setContentCompressionResistancePriority(.required, for: .horizontal)
        date.setContentHuggingPriority(.required, for: .horizontal)
        pie.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pie)
        textField = subject
        NSLayoutConstraint.activate([
            subject.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            subject.trailingAnchor.constraint(equalTo: pie.leadingAnchor, constant: -6),
            subject.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            meta.leadingAnchor.constraint(equalTo: subject.leadingAnchor),
            meta.trailingAnchor.constraint(lessThanOrEqualTo: date.leadingAnchor, constant: -6),
            meta.topAnchor.constraint(equalTo: subject.bottomAnchor, constant: 2),
            date.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            date.firstBaselineAnchor.constraint(equalTo: meta.firstBaselineAnchor),
            pie.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            pie.centerYAnchor.constraint(equalTo: subject.centerYAnchor),
            pie.widthAnchor.constraint(equalToConstant: 14),
            pie.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { pie.needsDisplay = true }
    }

    /// Fills in the row for a commit.
    ///
    /// The meta line shows the sha, then the refs (they identify the commit), then the author,
    /// which truncates first.
    func configure(subject s: String, sha: String, author: String?, date d: Date, refs: [String], progress: (done: Int, total: Int)) {
        subject.stringValue = s
        subject.textColor = progress.total > 0 && progress.done == progress.total ? .secondaryLabelColor : .labelColor
        let secondary = NSColor.secondaryLabelColor
        let m = NSMutableAttributedString(string: sha, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular), .foregroundColor: secondary])
        for r in refs.prefix(3) {
            m.append(NSAttributedString(string: "  " + r, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.controlAccentColor]))
        }
        if let author {
            m.append(NSAttributedString(string: "  " + author, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: secondary]))
        }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        m.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: m.length))
        meta.attributedStringValue = m
        date.stringValue = compactDate(d)
        toolTip = "\(s)\n\(author ?? "")  \(d.formatted(date: .abbreviated, time: .shortened))" + (refs.isEmpty ? "" : "\n" + refs.joined(separator: ", "))
        pie.isHidden = progress.done == 0
        pie.fraction = progress.total == 0 ? 0 : CGFloat(progress.done) / CGFloat(progress.total)
    }
}
