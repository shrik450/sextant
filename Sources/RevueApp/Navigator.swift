import AppKit
import RevueCore

@MainActor
protocol NavigatorDelegate: AnyObject {
    func navigatorSelectScope(_ scope: Scope)
    func navigatorOpen(path: String, line: Int?)
    /// Opens a search result.
    func navigatorOpenResult(path: String, line: Int)
    func navigatorShowOverview()
    func navigatorToggleReviewed(_ paths: [String])
    func navigatorFileMenu(_ paths: [String]) -> NSMenu?
    func navigatorCommitMenu(_ commit: Commit) -> NSMenu?
    func navigatorSearch(_ query: String, word: Bool, caseSensitive: Bool)
    /// Tells the delegate that choosing is done (Return in a field) and reading comes next.
    func navigatorFocusReader()
}

/// The left column, which chooses what to read.
///
/// Changes lists the review's commits and its files as a tree, and Find searches the snapshot.
@MainActor
final class Navigator: NSViewController {
    enum Tab: Int, CaseIterable { case changes, find }

    weak var delegate: NavigatorDelegate? {
        didSet {
            changes.delegate = delegate
            search.delegate = delegate
        }
    }
    let changes = ChangesController()
    let search = SearchController()
    private let tabs = NSSegmentedControl()
    private let container = NSView()
    private(set) var tab: Tab = .changes
    var onTabChanged: (() -> Void)?

    override func loadView() {
        let v = NSView()
        let names = ["Changes", "Find"]
        tabs.segmentCount = names.count
        tabs.trackingMode = .selectOne
        tabs.segmentDistribution = .fillEqually
        for (i, name) in names.enumerated() {
            tabs.setLabel(name, forSegment: i)
            tabs.setToolTip("\(name) (⌘\(i + 1))", forSegment: i)
        }
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(tabs)
        v.addSubview(container)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: v.safeAreaLayoutGuide.topAnchor, constant: 4),
            tabs.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),
            container.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 8),
            container.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        view = v
        for c in [changes, search] as [NSViewController] { addChild(c) }
        show(.changes)
    }

    @objc private func tabChanged() { show(Tab(rawValue: tabs.selectedSegment) ?? .changes) }

    func show(_ t: Tab, focus: Bool = false) {
        defer { onTabChanged?() }
        tab = t
        tabs.selectedSegment = t.rawValue
        container.subviews.forEach { $0.removeFromSuperview() }
        let v = [changes, search][t.rawValue].view
        v.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: container.topAnchor),
            v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        if focus { view.window?.makeFirstResponder(t == .find ? search.field : focusView) }
    }

    /// The list that takes focus when the navigator does.
    var focusView: NSView {
        switch tab {
        case .changes: changes.outline
        case .find: search.outline
        }
    }
}

/// A row of the commits list: the whole review, its uncommitted work, or one of its commits.
enum ScopeRow: Equatable {
    case everything(title: String, detail: String)
    case uncommitted(count: Int)
    case commit(Commit)
}

/// What the reader shows, for highlighting it in the file tree.
enum ReaderFocus: Equatable {
    case none, overview
    case file(String)
}

/// The Changes tab: the review's commits, to narrow what's read, above its files as a tree.
///
/// The tree folds unchanged files away like the reader folds unchanged lines, and its filter
/// finds any file in the snapshot.
@MainActor
final class ChangesController: NSViewController {
    final class Item: NSObject {
        enum Kind { case allChanges, folder, file, folded }
        let kind: Kind
        let name: String
        let path: String
        let file: FileState?
        let changed: Int
        let reviewed: Int
        /// Whether the row shows its folder, as filter results do.
        let showsFolder: Bool
        var children: [Item] = []

        init(kind: Kind, name: String, path: String, file: FileState? = nil, changed: Int = 0, reviewed: Int = 0, showsFolder: Bool = false) {
            self.kind = kind
            self.name = name
            self.path = path
            self.file = file
            self.changed = changed
            self.reviewed = reviewed
            self.showsFolder = showsFolder
        }
    }

    weak var delegate: NavigatorDelegate?
    weak var reviews: ReviewStore?
    let commits = KeyTableView()
    let outline = KeyOutlineView()
    let filter = NSSearchField()
    private let mode = NSSegmentedControl(images: [NSImage(systemSymbolName: "plusminus", accessibilityDescription: "Changed Files")!, NSImage(systemSymbolName: "folder", accessibilityDescription: "All Files")!], trackingMode: .selectOne, target: nil, action: nil)
    private let split = NSSplitView()
    private let commitsScroll = NSScrollView()
    private(set) var scopeRows: [ScopeRow] = []
    private var files: [FileState] = []
    private var paths: [String] = []
    private var revealed: Set<String> = []
    private var expansion: [String: Bool] = [:]
    private var items: [Item] = []
    private var focus: ReaderFocus = .none
    private var suppress = false
    private var placedSplit = false

    /// Whether every file shows, rather than changed files with the rest folded away.
    ///
    /// Choosing changed files folds away again any unchanged files the user unfolded.
    var showsUnchanged: Bool {
        get { UserDefaults.standard.bool(forKey: "showUnchangedFiles") }
        set {
            if !newValue { revealed = [] }
            UserDefaults.standard.set(newValue, forKey: "showUnchangedFiles")
            mode.selectedSegment = newValue ? 1 : 0
            rebuild()
        }
    }

    override func loadView() {
        let v = NSView()
        let commitColumn = NSTableColumn(identifier: .init("commit"))
        commitColumn.resizingMask = .autoresizingMask
        commits.addTableColumn(commitColumn)
        commits.headerView = nil
        commits.style = .sourceList
        commits.allowsMultipleSelection = true
        commits.dataSource = self
        commits.delegate = self
        commits.menu = NSMenu()
        commits.menu?.delegate = self
        commits.setAccessibilityLabel("Commits")
        commitsScroll.documentView = commits
        commitsScroll.hasVerticalScroller = true
        commitsScroll.autohidesScrollers = true
        commitsScroll.drawsBackground = false

        let column = NSTableColumn(identifier: .init("file"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowHeight = 24
        outline.indentationPerLevel = 12
        outline.allowsMultipleSelection = true
        outline.autoresizesOutlineColumn = false
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(outlineClicked)
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        outline.onSpace = { [weak self] in self?.toggleSelected() }
        outline.onReturn = { [weak self] in self?.enterSelected() }
        outline.setAccessibilityLabel("Files")
        let outlineScroll = NSScrollView()
        outlineScroll.documentView = outline
        outlineScroll.hasVerticalScroller = true
        outlineScroll.autohidesScrollers = true
        outlineScroll.drawsBackground = false
        outlineScroll.translatesAutoresizingMaskIntoConstraints = false

        filter.placeholderString = "Find File"
        filter.delegate = self
        filter.sendsSearchStringImmediately = true
        filter.translatesAutoresizingMaskIntoConstraints = false
        mode.selectedSegment = showsUnchanged ? 1 : 0
        mode.setWidth(30, forSegment: 0)
        mode.setWidth(30, forSegment: 1)
        mode.target = self
        mode.action = #selector(modeChanged)
        mode.setToolTip("Changed Files, with the rest folded away (⌃⌘U)", forSegment: 0)
        mode.setToolTip("All Files (⌃⌘U)", forSegment: 1)
        mode.translatesAutoresizingMaskIntoConstraints = false
        mode.setContentCompressionResistancePriority(.required, for: .horizontal)

        let filesPane = NSView()
        filesPane.addSubview(filter)
        filesPane.addSubview(mode)
        filesPane.addSubview(outlineScroll)
        NSLayoutConstraint.activate([
            filter.topAnchor.constraint(equalTo: filesPane.topAnchor, constant: 6),
            filter.leadingAnchor.constraint(equalTo: filesPane.leadingAnchor, constant: 10),
            filter.trailingAnchor.constraint(equalTo: mode.leadingAnchor, constant: -6),
            mode.trailingAnchor.constraint(equalTo: filesPane.trailingAnchor, constant: -10),
            mode.centerYAnchor.constraint(equalTo: filter.centerYAnchor),
            outlineScroll.topAnchor.constraint(equalTo: filter.bottomAnchor, constant: 6),
            outlineScroll.leadingAnchor.constraint(equalTo: filesPane.leadingAnchor),
            outlineScroll.trailingAnchor.constraint(equalTo: filesPane.trailingAnchor),
            outlineScroll.bottomAnchor.constraint(equalTo: filesPane.bottomAnchor),
        ])

        split.isVertical = false
        split.dividerStyle = .thin
        split.arrangesAllSubviews = true
        split.delegate = self
        split.addArrangedSubview(commitsScroll)
        split.addArrangedSubview(filesPane)
        split.setHoldingPriority(.defaultLow + 10, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        split.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: v.topAnchor),
            split.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        commitsScroll.isHidden = true
        view = v
        NotificationCenter.default.addObserver(self, selector: #selector(itemExpanded(_:)), name: NSOutlineView.itemDidExpandNotification, object: outline)
        NotificationCenter.default.addObserver(self, selector: #selector(itemCollapsed(_:)), name: NSOutlineView.itemDidCollapseNotification, object: outline)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        placeSplitIfNeeded()
    }

    /// Gives the commits list room for its rows, up to a third of the column, once it has some.
    private func placeSplitIfNeeded() {
        guard !placedSplit, !commitsScroll.isHidden, split.bounds.height > 0 else { return }
        placedSplit = true
        let wanted = (0..<commits.numberOfRows).reduce(CGFloat(8)) { $0 + commits.rect(ofRow: $1).height }
        split.setPosition(min(wanted, split.bounds.height / 3), ofDividerAt: 0)
    }

    /// Lists the review's scopes and commits, selecting the one being read.
    func setScopes(_ rows: [ScopeRow], selected scope: Scope) {
        let changed = rows != scopeRows
        scopeRows = rows
        commitsScroll.isHidden = rows.count <= 1
        if changed {
            suppress = true
            commits.reloadData()
            suppress = false
            placedSplit = false
            view.needsLayout = true
        }
        showScope(scope)
    }

    func showScope(_ scope: Scope) {
        var rows = IndexSet()
        switch scope {
        case .everything: if case .everything? = scopeRows.first { rows = [0] }
        case .uncommitted: if let i = scopeRows.firstIndex(where: { if case .uncommitted = $0 { true } else { false } }) { rows = [i] }
        case .commits(let newest, let oldest):
            if let a = row(ofCommit: newest), let b = row(ofCommit: oldest) { rows = IndexSet(integersIn: min(a, b)...max(a, b)) }
        case .staged, .unstaged: break
        }
        suppress = true
        commits.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first { commits.scrollRowToVisible(first) }
        suppress = false
    }

    private func row(ofCommit oid: String) -> Int? {
        scopeRows.firstIndex { if case .commit(let c) = $0 { c.oid == oid } else { false } }
    }

    private func commit(atRow r: Int) -> Commit? {
        guard scopeRows.indices.contains(r), case .commit(let c) = scopeRows[r] else { return nil }
        return c
    }

    /// The scope a selection of rows stands for: one row, or the run of commits it spans.
    private func scope(forRows rows: IndexSet) -> Scope? {
        let commitRows = rows.filter { commit(atRow: $0) != nil }
        if let lo = commitRows.min(), let hi = commitRows.max(), let newest = commit(atRow: lo), let oldest = commit(atRow: hi) {
            return .commits(newest: newest.oid, oldest: oldest.oid)
        }
        guard let r = rows.first, scopeRows.indices.contains(r) else { return nil }
        switch scopeRows[r] {
        case .everything: return .everything
        case .uncommitted: return .uncommitted
        case .commit: return nil
        }
    }

    /// Moves to the next older (+1) or newer (-1) commit, starting from the whole review.
    func stepCommit(_ dir: Int) -> Bool {
        let commitRows = scopeRows.indices.filter { commit(atRow: $0) != nil }
        guard !commitRows.isEmpty else { return false }
        let selected = commits.selectedRowIndexes
        let next: Int?
        if let cur = dir > 0 ? selected.max() : selected.min(), commit(atRow: cur) != nil {
            next = dir > 0 ? commitRows.first { $0 > cur } : commitRows.last { $0 < cur } ?? (scopeRows.first.flatMap { if case .everything = $0 { 0 } else { nil } })
        } else {
            next = dir > 0 ? commitRows.first : nil
        }
        guard let next, let scope = scope(forRows: [next]) else { return false }
        showScope(scope)
        delegate?.navigatorSelectScope(scope)
        return true
    }

    func refreshCommitProgress() {
        let rows = IndexSet(scopeRows.indices.filter { commit(atRow: $0) != nil })
        commits.reloadData(forRowIndexes: rows, columnIndexes: [0])
    }

    /// Shows a review's changes among every file in its snapshot.
    func setFiles(_ changes: [FileState], paths: [String]) {
        if changes.map(\.path) != files.map(\.path) { revealed = [] }
        files = changes
        self.paths = paths
        rebuild()
    }

    func refreshReviewState() { rebuild() }

    /// Highlights what the reader shows, without telling the delegate.
    func showFocus(_ f: ReaderFocus) {
        focus = f
        selectFocus()
    }

    private func selectFocus() {
        let target: Item? = switch focus {
        case .overview: items.first { $0.kind == .allChanges }
        case .file(let p): find(p, in: items)
        case .none: nil
        }
        suppress = true
        defer { suppress = false }
        guard let target else { outline.deselectAll(nil); return }
        var parent = outline.parent(forItem: target)
        var chain: [Any] = []
        while let p = parent { chain.append(p); parent = outline.parent(forItem: p) }
        for p in chain.reversed() { outline.expandItem(p) }
        let r = outline.row(forItem: target)
        guard r >= 0 else { return }
        if outline.selectedRowIndexes != [r] { outline.selectRowIndexes([r], byExtendingSelection: false) }
        outline.scrollRowToVisible(r)
    }

    private func find(_ path: String, in items: [Item]) -> Item? {
        for i in items {
            if i.kind == .file, i.path == path { return i }
            if i.kind == .folder, path.hasPrefix(i.path + "/"), let hit = find(path, in: i.children) { return hit }
        }
        return nil
    }

    private var query: String { filter.stringValue.trimmingCharacters(in: .whitespaces) }

    private func rebuild() {
        let byPath = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        if !query.isEmpty {
            let all = Array(Set(paths).union(byPath.keys))
            items = rankFuzzy(query, all).prefix(500).map { Item(kind: .file, name: $0, path: $0, file: byPath[$0], showsFolder: true) }
        } else {
            let changed = Set(byPath.keys)
            let reviewed = Set(files.filter(\.reviewed).map(\.path))
            let tree = fileTree(paths: paths, changed: changed, reviewed: reviewed, showUnchanged: showsUnchanged, revealed: revealed)
            items = (files.count > 1 ? [Item(kind: .allChanges, name: "All Changes", path: "", changed: files.count, reviewed: reviewed.count)] : [])
                + tree.map { item($0, byPath) }
        }
        suppress = true
        outline.reloadData()
        expand(items)
        suppress = false
        selectFocus()
    }

    private func item(_ n: FileNode, _ byPath: [String: FileState]) -> Item {
        switch n.kind {
        case .file: return Item(kind: .file, name: n.name, path: n.path, file: byPath[n.path])
        case .unchanged(let count): return Item(kind: .folded, name: "", path: n.path, changed: count)
        case .folder:
            let i = Item(kind: .folder, name: n.name, path: n.path, changed: n.changed, reviewed: n.reviewed)
            i.children = n.children.map { item($0, byPath) }
            return i
        }
    }

    /// Opens the folders that should be open.
    ///
    /// When only changed files show, nearly every folder opens, so it expands them all in one
    /// pass and folds the rest, since expanding folders one at a time recounts the rows each
    /// time. With unchanged files showing, most folders stay closed, so it opens just those.
    private func expand(_ items: [Item]) {
        if showsUnchanged {
            expandEach(items)
        } else {
            outline.expandItem(nil, expandChildren: true)
            foldClosed(items)
        }
    }

    private func expandEach(_ items: [Item]) {
        for i in items where i.kind == .folder && shouldOpen(i) {
            outline.expandItem(i)
            expandEach(i.children)
        }
    }

    private func foldClosed(_ items: [Item]) {
        for i in items where i.kind == .folder {
            foldClosed(i.children)
            if !shouldOpen(i) { outline.collapseItem(i) }
        }
    }

    private func shouldOpen(_ i: Item) -> Bool { expansion[i.path] ?? (i.changed > 0) }

    @objc private func itemExpanded(_ n: Notification) {
        guard !suppress, let i = n.userInfo?["NSObject"] as? Item else { return }
        expansion[i.path] = true
    }

    /// Remembers a folder the user closed, and folds away again the unchanged files they had
    /// unfolded inside it.
    @objc private func itemCollapsed(_ n: Notification) {
        guard !suppress, let i = n.userInfo?["NSObject"] as? Item else { return }
        expansion[i.path] = false
        let unfolded = revealed.filter { $0 == i.path || $0.hasPrefix(i.path + "/") }
        guard !unfolded.isEmpty else { return }
        revealed.subtract(unfolded)
        Task { [weak self] in self?.rebuild() }
    }

    @objc private func modeChanged() { showsUnchanged = mode.selectedSegment == 1 }

    /// Moves into the reader, which already shows the selected file, or opens or closes the
    /// selected folder.
    private func enterSelected() {
        guard outline.selectedRowIndexes.count == 1, let i = outline.item(atRow: outline.selectedRow) as? Item else { return }
        switch i.kind {
        case .file, .allChanges:
            delegate?.navigatorFocusReader()
        case .folder:
            if outline.isItemExpanded(i) { outline.collapseItem(i) } else { outline.expandItem(i) }
        case .folded:
            break
        }
    }

    /// The changed files the selected rows stand for, folders standing for the changes inside them.
    private func changedPaths(_ rows: IndexSet) -> [String] {
        var out: [String] = []
        for r in rows {
            guard let i = outline.item(atRow: r) as? Item else { continue }
            switch i.kind {
            case .allChanges: return files.map(\.path)
            case .file: if let f = i.file { out.append(f.path) }
            case .folder: out += files.map(\.path).filter { $0.hasPrefix(i.path + "/") }
            case .folded: break
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    var selectedPaths: [String] { changedPaths(outline.selectedRowIndexes) }

    func toggleSelected() {
        let paths = selectedPaths
        if !paths.isEmpty { delegate?.navigatorToggleReviewed(paths) }
    }

    @objc private func outlineClicked() {
        guard let i = outline.item(atRow: outline.clickedRow) as? Item, i.kind == .folded else { return }
        reveal(i)
    }

    private func reveal(_ i: Item) {
        revealed.insert(i.path)
        rebuild()
    }

    private func activate(_ i: Item) {
        switch i.kind {
        case .allChanges: delegate?.navigatorShowOverview()
        case .file: delegate?.navigatorOpen(path: i.path, line: nil)
        case .folded, .folder: break
        }
    }
}

extension ChangesController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { scopeRows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .commit = scopeRows[row] { 46 } else { 28 }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch scopeRows[row] {
        case .everything(let title, let detail):
            let cell = (tableView.makeView(withIdentifier: TargetCell.id, owner: nil) as? TargetCell) ?? TargetCell()
            cell.configure(title: title, symbol: "square.stack.3d.up", count: 0)
            cell.toolTip = detail
            return cell
        case .uncommitted(let n):
            let cell = (tableView.makeView(withIdentifier: TargetCell.id, owner: nil) as? TargetCell) ?? TargetCell()
            cell.configure(title: "Uncommitted", symbol: "pencil.and.list.clipboard", count: n)
            cell.toolTip = "Work in the checkout that isn’t committed yet"
            return cell
        case .commit(let c):
            let cell = (tableView.makeView(withIdentifier: CommitCell.id, owner: nil) as? CommitCell) ?? CommitCell()
            cell.configure(subject: c.subject, sha: c.shortOid, author: c.author, date: c.date, refs: c.refs,
                           progress: reviews?.progress(c.changes) ?? (0, 0))
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppress, let scope = scope(forRows: commits.selectedRowIndexes) else { return }
        showScope(scope)
        delegate?.navigatorSelectScope(scope)
    }
}

extension ChangesController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { PillRowView() }

    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Item)?.children.count ?? items.count
    }

    func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Item)?.children[index] ?? items[index]
    }

    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? Item)?.kind == .folder }

    func outlineView(_ o: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let i = item as? Item else { return nil }
        let cell = (o.makeView(withIdentifier: TreeCell.id, owner: nil) as? TreeCell) ?? TreeCell()
        switch i.kind {
        case .allChanges: cell.configure(.allChanges(reviewed: i.reviewed, changed: i.changed))
        case .folder: cell.configure(.folder(i.name, reviewed: i.reviewed, changed: i.changed))
        case .folded: cell.configure(.folded(i.changed))
        case .file:
            if let f = i.file {
                cell.configure(.change(f, showsFolder: i.showsFolder))
                cell.onToggle = { [weak self] in self?.delegate?.navigatorToggleReviewed([f.path]) }
            } else {
                cell.configure(.file(i.path, showsFolder: i.showsFolder))
            }
        }
        return cell
    }

    /// Keeps folded unchanged files out of the selection, so moving through the tree goes from
    /// change to change; clicking them unfolds them instead.
    func outlineView(_ o: NSOutlineView, shouldSelectItem item: Any) -> Bool { (item as? Item)?.kind != .folded }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppress, outline.selectedRowIndexes.count == 1, let i = outline.item(atRow: outline.selectedRow) as? Item else { return }
        activate(i)
    }
}

extension ChangesController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { rebuild() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            guard let first = items.first(where: { $0.kind == .file }) else { NSSound.beep(); return true }
            delegate?.navigatorOpen(path: first.path, line: nil)
            delegate?.navigatorFocusReader()
            return true
        }
        if sel == #selector(NSResponder.moveDown(_:)) {
            view.window?.makeFirstResponder(outline)
            if outline.selectedRow < 0, outline.numberOfRows > 0 { outline.selectRowIndexes([0], byExtendingSelection: false) }
            return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            if query.isEmpty { delegate?.navigatorFocusReader() } else { filter.stringValue = ""; rebuild() }
            return true
        }
        return false
    }
}

extension ChangesController: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt i: Int) -> CGFloat { max(proposed, 52) }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt i: Int) -> CGFloat { min(proposed, splitView.bounds.height - 120) }
}

extension ChangesController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let built: NSMenu?
        if menu === commits.menu {
            built = commit(atRow: commits.clickedRow).flatMap { delegate?.navigatorCommitMenu($0) }
        } else {
            let clicked = outline.clickedRow
            let rows = clicked >= 0 && !outline.selectedRowIndexes.contains(clicked) ? IndexSet(integer: clicked) : outline.selectedRowIndexes
            let paths = changedPaths(rows)
            built = paths.isEmpty ? nil : delegate?.navigatorFileMenu(paths)
        }
        guard let built else { return }
        for item in built.items { built.removeItem(item); menu.addItem(item) }
    }
}

/// Returns the status letter and colour for a change, as shown in lists.
func statusLetter(_ status: Character) -> (String, NSColor) {
    switch status {
    case "A": ("A", .themed("success"))
    case "?": ("U", .themed("success"))
    case "D": ("D", .themed("danger"))
    case "R": ("R", .themed("accent"))
    case "C": ("C", .themed("accent"))
    case "T": ("T", .themed("attention"))
    case "U": ("!", .themed("danger"))
    default: ("M", .themed("attention"))
    }
}

/// Text search results across the snapshot, grouped by file.
///
/// Also lists definitions and usages.
@MainActor
final class SearchController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { PillRowView() }

    final class Group: NSObject {
        let path: String
        var matches: [GrepMatch]
        var definitionLines: Set<Int>
        init(path: String, matches: [GrepMatch], definitionLines: Set<Int>) { self.path = path; self.matches = matches; self.definitionLines = definitionLines }
    }
    final class Item: NSObject {
        let group: Group
        let match: GrepMatch
        init(group: Group, match: GrepMatch) { self.group = group; self.match = match }
    }

    weak var delegate: NavigatorDelegate?
    let field = NSSearchField()
    let outline = KeyOutlineView()
    let status = NSTextField(labelWithString: "")
    private var suppressOpen = false
    private var groups: [Group] = []
    private var items: [ObjectIdentifier: [Item]] = [:]
    private var query = ""
    var wholeWord = false
    var caseSensitive = false

    override func loadView() {
        let v = NSView()
        field.placeholderString = "Find in Files"
        field.sendsWholeSearchString = true
        field.delegate = self
        field.target = self
        field.action = #selector(run)
        field.translatesAutoresizingMaskIntoConstraints = false
        let menu = NSMenu()
        let w = menu.addItem(withTitle: "Whole Words", action: #selector(toggleWord(_:)), keyEquivalent: "")
        w.target = self
        let c = menu.addItem(withTitle: "Match Case", action: #selector(toggleCase(_:)), keyEquivalent: "")
        c.target = self
        menu.delegate = self
        (field.cell as? NSSearchFieldCell)?.searchMenuTemplate = menu
        let col = NSTableColumn(identifier: .init("m"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowHeight = 24
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked)
        outline.onReturn = { [weak self] in self?.enterSelected() }
        outline.onEscape = { [weak self] in self?.delegate?.navigatorFocusReader() }
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(field)
        v.addSubview(scroll)
        v.addSubview(status)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: v.topAnchor, constant: 2),
            field.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -6),
            status.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),
            status.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -10),
        ])
        view = v
    }

    @objc private func toggleWord(_ s: NSMenuItem) { wholeWord.toggle(); run() }
    @objc private func toggleCase(_ s: NSMenuItem) { caseSensitive.toggle(); run() }

    @objc func run() {
        let q = field.stringValue
        guard !q.isEmpty else { return }
        status.stringValue = "Searching…"
        delegate?.navigatorSearch(q, word: wholeWord, caseSensitive: caseSensitive)
    }

    func begin(_ q: String, word: Bool) {
        field.stringValue = q
        wholeWord = word
        status.stringValue = "Searching…"
    }

    /// Shows search results.
    ///
    /// Groups holding definitions come first, with their definition lines marked.
    func show(_ matches: [GrepMatch], title: String, definitions: [String: Set<Int>] = [:], capped: Bool) {
        var byPath: [String: [GrepMatch]] = [:]
        var order: [String] = []
        for m in matches {
            if byPath[m.path] == nil { order.append(m.path) }
            byPath[m.path, default: []].append(m)
        }
        groups = order.map { Group(path: $0, matches: byPath[$0]!, definitionLines: definitions[$0] ?? []) }
        groups.sort { ($0.definitionLines.isEmpty ? 1 : 0) < ($1.definitionLines.isEmpty ? 1 : 0) }
        items = [:]
        for g in groups { items[ObjectIdentifier(g)] = g.matches.map { Item(group: g, match: $0) } }
        query = title
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        let n = matches.count
        status.stringValue = n == 0 ? "No results" : "\(n) result\(n == 1 ? "" : "s") in \(groups.count) file\(groups.count == 1 ? "" : "s")" + (capped ? ", showing the first \(n)" : "")
    }

    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return groups.count }
        if let g = item as? Group { return items[ObjectIdentifier(g)]?.count ?? 0 }
        return 0
    }

    func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let g = item as? Group { return items[ObjectIdentifier(g)]![index] }
        return groups[index]
    }

    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { item is Group }

    func outlineView(_ o: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let id = NSUserInterfaceItemIdentifier(item is Group ? "SG" : "SI")
        let cell = (o.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = id
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = item is Group ? .byTruncatingHead : .byTruncatingTail
            tf.maximumNumberOfLines = 1
            tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            c.addSubview(tf)
            c.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        if let g = item as? Group {
            let s = NSMutableAttributedString(string: (g.path as NSString).lastPathComponent, attributes: [.font: NSFont.systemFont(ofSize: NSFont.row.pointSize, weight: .semibold)])
            let dir = (g.path as NSString).deletingLastPathComponent
            if !dir.isEmpty { s.append(NSAttributedString(string: "  " + dir, attributes: [.font: NSFont.detail, .foregroundColor: NSColor.themed("fgMuted")])) }
            cell.textField?.attributedStringValue = truncatingTail(s)
            cell.toolTip = g.path
        } else if let it = item as? Item {
            let m = it.match
            let isDef = it.group.definitionLines.contains(m.line)
            let mono = NSFont.monospacedSystemFont(ofSize: NSFont.detail.pointSize, weight: isDef ? .semibold : .regular)
            let s = NSMutableAttributedString(string: "\(m.line)  ", attributes: [.font: NSFont.detailDigits, .foregroundColor: NSColor.themed("fgMuted")])
            var text = m.text.trimmingCharacters(in: .whitespaces) as NSString
            var r = text.range(of: query, options: caseSensitive ? [] : .caseInsensitive)
            if r.location != NSNotFound, r.location > 16 {
                let cut = r.location - 10
                text = ("…" + text.substring(from: cut)) as NSString
                r.location -= cut - 1
            }
            let start = s.length
            s.append(NSAttributedString(string: text as String, attributes: [.font: mono, .foregroundColor: NSColor.themed("fg")]))
            if r.location != NSNotFound {
                s.addAttribute(.backgroundColor, value: NSColor.themed("findMatch"), range: NSRange(location: start + r.location, length: r.length))
            }
            cell.textField?.attributedStringValue = truncatingTail(s)
            cell.toolTip = isDef ? "Definition" : nil
        }
        return cell
    }

    func outlineView(_ o: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is Item }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        if !suppressOpen { clicked() }
    }

    @objc private func clicked() {
        guard let it = outline.item(atRow: outline.selectedRow) as? Item else { return }
        delegate?.navigatorOpenResult(path: it.group.path, line: it.match.line)
    }

    /// Puts the keyboard on the results, selecting the first if none is, without opening it.
    func focusResults() {
        view.window?.makeFirstResponder(outline)
        guard outline.selectedRow < 0, let first = (0..<outline.numberOfRows).first(where: { outline.item(atRow: $0) is Item }) else { return }
        suppressOpen = true
        outline.selectRowIndexes([first], byExtendingSelection: false)
        suppressOpen = false
        outline.scrollRowToVisible(first)
    }

    /// Opens the selected result and moves into the pane showing it.
    private func enterSelected() {
        guard outline.item(atRow: outline.selectedRow) is Item else { return }
        clicked()
        delegate?.navigatorFocusReader()
    }
}

extension SearchController {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard sel == #selector(NSResponder.moveDown(_:)), outline.numberOfRows > 0 else { return false }
        focusResults()
        return true
    }
}

extension SearchController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(withTitle: "Whole Words")?.state = wholeWord ? .on : .off
        menu.item(withTitle: "Match Case")?.state = caseSensitive ? .on : .off
    }
}

/// Keeps a one-line result to its line, cutting its end off when it doesn't fit, rather than
/// wrapping its last words out of sight.
private func truncatingTail(_ text: NSMutableAttributedString) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
    return text
}
