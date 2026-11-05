import AppKit
import SextantCore

/// The popover that chooses what to review: a worktree, pull request, branch, commit or stash, or
/// a typed revision or range.
@MainActor
final class SubjectPicker: NSViewController {
    enum Row {
        case section(String)
        case worktree(Worktree)
        case pullRequest(PullRequest)
        case branch(Branch)
        case commit(Commit)
        case stash(Stash)
        /// A typed expression such as `HEAD~3`, `main...feature` or `#12`.
        case typed(String, RevisionSpec)

        var isSection: Bool { if case .section = self { true } else { false } }
    }

    let field = NSSearchField()
    let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private let repository: Repository
    private let current: Review?
    private let here: URL?
    private let onChoose: (Review) -> Void
    private(set) var rows: [Row] = []
    private var found: [Commit] = []
    private var searchTask: Task<Void, Never>?

    /// - Parameters:
    ///   - here: The checkout being read, which typed `staged` or `uncommitted` refer to.
    ///   - onChoose: Called with the chosen review.
    init(repository: Repository, current: Review?, here: URL?, onChoose: @escaping (Review) -> Void) {
        self.repository = repository
        self.current = current
        self.here = here
        self.onChoose = onChoose
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 500))
        field.placeholderString = "Worktrees, Pull Requests, Branches, Commits"
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.translatesAutoresizingMaskIntoConstraints = false
        let column = NSTableColumn(identifier: .init("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.floatsGroupRows = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(chooseSelected)
        table.refusesFirstResponder = true
        table.setAccessibilityLabel("Things to review")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.translatesAutoresizingMaskIntoConstraints = false
        for s in [field, scroll, status] as [NSView] { v.addSubview(s) }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: v.topAnchor, constant: 12),
            field.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -6),
            status.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 14),
            status.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -14),
            status.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -8),
        ])
        view = v
        preferredContentSize = v.frame.size
        rebuild()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(field)
        Task {
            await repository.loadPullRequests()
            rebuild()
        }
    }

    private var query: String { field.stringValue.trimmingCharacters(in: .whitespaces) }

    /// Whether every word of the query appears in one of the texts.
    private func matches(_ texts: String...) -> Bool {
        let words = query.lowercased().split(separator: " ")
        let hay = texts.joined(separator: " ").lowercased()
        return words.allSatisfy { hay.contains($0) }
    }

    private func rebuild() {
        let keep = selectedKey
        let q = query
        var out: [Row] = []
        func section(_ title: String, _ items: [Row]) {
            guard !items.isEmpty else { return }
            out.append(.section(title))
            out += items
        }
        let typed = parseRevisionSpec(q).flatMap { spec -> Row? in
            if case .revision = spec, !looksLikeRevision(q) { return nil }
            return .typed(q, spec)
        }
        if let typed { section("Go To", [typed]) }
        section("Worktrees", repository.worktrees.filter { w in
            q.isEmpty || matches(w.name, w.branch ?? "", w.root.path)
        }.map(Row.worktree))
        let prs = (repository.pullRequests ?? []).sorted { $0.updatedAt > $1.updatedAt }.filter { p in
            q.isEmpty || matches("#\(p.number)", p.title, p.headRefName, p.author.login)
        }
        section("Pull Requests", prs.prefix(q.isEmpty ? 30 : 100).map(Row.pullRequest))
        let locals = Dictionary(repository.branches.filter { !$0.isRemote }.map { ($0.name, $0.oid) }, uniquingKeysWith: { a, _ in a })
        let branches = repository.branches.filter { b in
            if b.isRemote, let slash = b.name.firstIndex(of: "/"), locals[String(b.name[b.name.index(after: slash)...])] == b.oid { return false }
            return q.isEmpty || matches(b.name, b.subject)
        }
        section("Branches", branches.prefix(q.isEmpty ? 40 : 150).map(Row.branch))
        section("Stashes", repository.stashes.filter { q.isEmpty || matches($0.ref, $0.subject) }.map(Row.stash))
        if !q.isEmpty { section("Commits", found.map(Row.commit)) }
        if out.isEmpty, !q.isEmpty, let spec = parseRevisionSpec(q) { section("Go To", [.typed(q, spec)]) }
        rows = out
        table.reloadData()
        let restored = keep.flatMap { k in rows.indices.first { key(rows[$0]) == k } }
        select(restored ?? rows.indices.first { !rows[$0].isSection })
        status.stringValue = repository.pullRequests == nil ? "No pull requests: they come from the GitHub CLI (gh), which can’t list them here" : ""
    }

    private func looksLikeRevision(_ s: String) -> Bool {
        if s.contains(" ") { return false }
        if s.count >= 4, s.allSatisfy(\.isHexDigit) { return true }
        return s.contains { "~^@:".contains($0) } || s.hasPrefix("refs/") || s == "HEAD"
    }

    private func key(_ r: Row) -> String {
        switch r {
        case .section(let s): "s:" + s
        case .worktree(let w): "w:" + w.root.path
        case .pullRequest(let p): "p:\(p.number)"
        case .branch(let b): "b:" + b.name
        case .commit(let c): "c:" + c.oid
        case .stash(let s): "z:" + s.oid
        case .typed(let s, _): "t:" + s
        }
    }

    private var selectedKey: String? {
        rows.indices.contains(table.selectedRow) ? key(rows[table.selectedRow]) : nil
    }

    private func select(_ r: Int?) {
        guard let r else { table.deselectAll(nil); return }
        table.selectRowIndexes([r], byExtendingSelection: false)
        table.scrollRowToVisible(r)
    }

    private func move(_ dir: Int) {
        var r = table.selectedRow + dir
        while rows.indices.contains(r), rows[r].isSection { r += dir }
        if rows.indices.contains(r) { select(r) } else { NSSound.beep() }
    }

    private func searchCommits() {
        searchTask?.cancel()
        let q = query
        guard q.count >= 2 else { found = []; return }
        let git = repository.git
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let commits = await git.searchCommits(q, limit: 30)
            guard !Task.isCancelled, q == query else { return }
            found = commits
            rebuild()
        }
    }

    @objc func chooseSelected() {
        guard rows.indices.contains(table.selectedRow) else { NSSound.beep(); return }
        let repo = repository
        switch rows[table.selectedRow] {
        case .section: NSSound.beep()
        case .worktree(let w): onChoose(Review(subject: .worktree(w.root), base: repo.base(for: .worktree(w.root))))
        case .pullRequest(let p): onChoose(Review(subject: .pullRequest(p.number), base: repo.base(for: .pullRequest(p.number))))
        case .branch(let b): onChoose(Review(subject: .branch(b.name), base: repo.base(for: .branch(b.name))))
        case .commit(let c): onChoose(Review(subject: .commit(c.oid)))
        case .stash(let s): onChoose(Review(subject: .stash(s.oid)))
        case .typed(_, let spec):
            Task {
                do {
                    onChoose(try await repo.review(for: spec, in: here))
                } catch {
                    status.stringValue = error.localizedDescription
                }
            }
        }
    }
}

extension SubjectPicker: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        found = []
        rebuild()
        searchCommits()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.insertNewline(_:)): chooseSelected()
        case #selector(NSResponder.cancelOperation(_:)):
            if query.isEmpty { dismiss(nil) } else { field.stringValue = ""; controlTextDidChange(Notification(name: NSControl.textDidChangeNotification)) }
        default: return false
        }
        return true
    }
}

extension SubjectPicker: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { rows[row].isSection }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rows[row].isSection ? 26 : 38 }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !rows[row].isSection }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if case .section(let title) = rows[row] {
            let id = NSUserInterfaceItemIdentifier("PickerSection")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
                let c = NSTableCellView()
                c.identifier = id
                let tf = NSTextField(labelWithString: "")
                tf.font = .systemFont(ofSize: 11, weight: .semibold)
                tf.textColor = .secondaryLabelColor
                tf.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(tf)
                c.textField = tf
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                    tf.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -3),
                ])
                return c
            }()
            cell.textField?.stringValue = title
            return cell
        }
        let cell = (tableView.makeView(withIdentifier: PickerCell.id, owner: nil) as? PickerCell) ?? PickerCell()
        configure(cell, rows[row])
        return cell
    }

    private func configure(_ cell: PickerCell, _ row: Row) {
        let isCurrent = current.map { isSubject(row, $0.subject) } ?? false
        switch row {
        case .section: break
        case .worktree(let w):
            let n = repository.uncommitted[w.root.path] ?? 0
            cell.set(symbol: "folder", title: w.name, detail: "\(w.branch ?? w.head.map { String($0.prefix(7)) } ?? "no commits")  ·  \(abbreviateHome(w.root.path))",
                     accessory: n > 0 ? "\(n) uncommitted" : "", current: isCurrent)
        case .pullRequest(let p):
            cell.set(symbol: "arrow.triangle.pull", title: "#\(p.number)  \(p.title)", detail: "\(p.headRefName) → \(p.baseRefName)  ·  \(p.author.login)",
                     accessory: (p.isDraft ? "Draft  ·  " : "") + compactDate(p.updatedAt), current: isCurrent)
        case .branch(let b):
            var distance = ""
            if let a = b.ahead, let behind = b.behind { distance = "↑\(a) ↓\(behind)  ·  " }
            cell.set(symbol: b.isRemote ? "cloud" : "arrow.triangle.branch", title: b.name, detail: b.subject,
                     accessory: distance + compactDate(b.date), current: isCurrent)
        case .commit(let c):
            cell.set(symbol: "smallcircle.filled.circle", title: c.subject, detail: "\(c.shortOid)  ·  \(c.author)", accessory: compactDate(c.date), current: isCurrent)
        case .stash(let s):
            cell.set(symbol: "tray", title: s.subject, detail: s.ref, accessory: compactDate(s.date), current: isCurrent)
        case .typed(let text, let spec):
            let (symbol, title): (String, String) = switch spec {
            case .comparison(let a, let b, let since): ("arrow.left.arrow.right", "Compare \(a)\(since ? "..." : "..")\(b)")
            case .pullRequest(let n): ("arrow.triangle.pull", "Pull request #\(n)")
            case .uncommitted: ("pencil.and.list.clipboard", "Uncommitted changes")
            case .staged: ("tray.full", "Staged changes")
            case .unstaged: ("tray", "Unstaged changes")
            case .revision(let r): ("arrow.right.circle", "Revision \(r)")
            }
            cell.set(symbol: symbol, title: title, detail: "Review ‘\(text)’", accessory: "↩", current: false)
        }
    }

    private func isSubject(_ row: Row, _ s: Subject) -> Bool {
        switch (row, s) {
        case (.worktree(let w), .worktree(let u)): w.root.standardizedFileURL == u.standardizedFileURL
        case (.pullRequest(let p), .pullRequest(let n)): p.number == n
        case (.branch(let b), .branch(let n)): b.name == n
        case (.commit(let c), .commit(let o)): c.oid == o
        case (.stash(let z), .stash(let o)): z.oid == o
        default: false
        }
    }
}

/// Shortens a path under the home folder to start with `~`.
func abbreviateHome(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

/// A two-line row of the subject picker.
@MainActor
final class PickerCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("PickerCell")
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let accessory = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = PickerCell.id
        icon.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: 13)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        accessory.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        accessory.textColor = .secondaryLabelColor
        accessory.alignment = .right
        for t in [title, detail] {
            t.lineBreakMode = .byTruncatingTail
            t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        accessory.setContentCompressionResistancePriority(.required, for: .horizontal)
        accessory.setContentHuggingPriority(.required, for: .horizontal)
        for v in [icon, title, detail, accessory] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        textField = title
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            title.trailingAnchor.constraint(lessThanOrEqualTo: accessory.leadingAnchor, constant: -8),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            accessory.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(symbol: String, title t: String, detail d: String, accessory a: String, current: Bool) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        title.stringValue = t
        title.font = .systemFont(ofSize: 13, weight: current ? .semibold : .regular)
        detail.stringValue = d
        accessory.stringValue = a
        toolTip = "\(t)\n\(d)"
    }
}
