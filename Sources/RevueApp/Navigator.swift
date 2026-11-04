import AppKit
import RevueCore

@MainActor
protocol NavigatorDelegate: AnyObject {
    func navigatorOpen(path: String, line: Int?)
    func navigatorSearch(_ query: String, word: Bool, caseSensitive: Bool)
    func navigatorOpenNote(_ note: Note)
    func navigatorDeleteNotes(_ ids: Set<UUID>)
    func navigatorCopyNotes(_ notes: [Note]?)
    /// Tells the delegate that choosing is done (Return in a field) and reading comes next.
    func navigatorFocusReader()
}

/// The middle column, which chooses what to look at.
///
/// It lists the changes in the target, every file in its tree, search results, or the
/// review's notes.
@MainActor
final class Navigator: NSViewController {
    enum Tab: Int, CaseIterable { case changes, files, search, notes }

    weak var delegate: NavigatorDelegate?
    let changes = FileListViewController()
    let tree = FileTreeController()
    let search = SearchController()
    let notes = NotesController()
    private let tabs = NSSegmentedControl()
    private let container = NSView()
    private(set) var tab: Tab = .changes

    override func loadView() {
        let v = NSView()
        let symbols = ["list.bullet.indent", "folder", "magnifyingglass", "text.bubble"]
        let names = ["Changes", "Files", "Search", "Notes"]
        tabs.segmentCount = symbols.count
        tabs.trackingMode = .selectOne
        tabs.segmentStyle = .automatic
        tabs.controlSize = .regular
        for (i, s) in symbols.enumerated() {
            tabs.setImage(NSImage(systemSymbolName: s, accessibilityDescription: names[i]), forSegment: i)
            tabs.setToolTip("\(names[i]) (⌘\(i + 1))", forSegment: i)
            tabs.setWidth(36, forSegment: i)
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
            tabs.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            container.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 6),
            container.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        view = v
        for c in [changes, tree, search, notes] as [NSViewController] { addChild(c) }
        show(.changes)
    }

    @objc private func tabChanged() { show(Tab(rawValue: tabs.selectedSegment) ?? .changes) }

    var onTabChanged: (() -> Void)?

    func show(_ t: Tab, focus: Bool = false) {
        defer { onTabChanged?() }
        tab = t
        tabs.selectedSegment = t.rawValue
        container.subviews.forEach { $0.removeFromSuperview() }
        let vc: NSViewController = [changes, tree, search, notes][t.rawValue]
        let v = vc.view
        v.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: container.topAnchor),
            v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        if focus {
            switch t {
            case .changes: view.window?.makeFirstResponder(changes.table)
            case .files: view.window?.makeFirstResponder(tree.filter)
            case .search: view.window?.makeFirstResponder(search.field)
            case .notes: view.window?.makeFirstResponder(notes.table)
            }
        }
    }

    /// The table that should take focus when the navigator does.
    var focusView: NSView {
        switch tab {
        case .changes: changes.table
        case .files: tree.outline
        case .search: search.outline
        case .notes: notes.table
        }
    }
}

/// Every file in the snapshot being reviewed, as a tree, with changed files marked.
@MainActor
final class FileTreeController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
    final class Node {
        let name: String
        let path: String
        var children: [Node] = []
        var isDir: Bool
        init(name: String, path: String, isDir: Bool) { self.name = name; self.path = path; self.isDir = isDir }
    }

    weak var delegate: NavigatorDelegate?
    let outline = NSOutlineView()
    let filter = NSSearchField()
    private var root = Node(name: "", path: "", isDir: true)
    private var all: [String] = []
    private var changed: [String: Character] = [:]
    private var flat: [Node]?
    private var suppress = false

    override func loadView() {
        let v = NSView()
        let col = NSTableColumn(identifier: .init("name"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.style = .inset
        outline.rowHeight = 22
        outline.dataSource = self
        outline.delegate = self
        outline.autoresizesOutlineColumn = false
        outline.setAccessibilityLabel("Files")
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        filter.placeholderString = "Filter"
        filter.delegate = self
        filter.sendsSearchStringImmediately = true
        filter.translatesAutoresizingMaskIntoConstraints = false
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
    }

    func setFiles(_ paths: [String], changed: [String: Character]) {
        let sorted = paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        self.changed = changed
        if sorted == all {
            outline.reloadData()
            return
        }
        let expanded = (0..<outline.numberOfRows).compactMap { r -> String? in
            guard let n = outline.item(atRow: r) as? Node, n.isDir, outline.isItemExpanded(n) else { return nil }
            return n.path
        }
        all = sorted
        root = Node(name: "", path: "", isDir: true)
        defer {
            for p in expanded { expand(p) }
        }
        var dirs: [String: Node] = ["": root]
        func dir(_ p: String) -> Node {
            if let d = dirs[p] { return d }
            let parent = dir((p as NSString).deletingLastPathComponent)
            let n = Node(name: (p as NSString).lastPathComponent, path: p, isDir: true)
            parent.children.append(n)
            dirs[p] = n
            return n
        }
        for p in all {
            let parent = dir((p as NSString).deletingLastPathComponent)
            parent.children.append(Node(name: (p as NSString).lastPathComponent, path: p, isDir: false))
        }
        func sort(_ n: Node) {
            n.children.sort { a, b in a.isDir != b.isDir ? a.isDir : a.name.localizedStandardCompare(b.name) == .orderedAscending }
            n.children.forEach(sort)
        }
        sort(root)
        applyFilter()
    }

    private func node(_ path: String) -> (Node, [Node])? {
        var node = root
        var chain: [Node] = []
        for comp in path.split(separator: "/") {
            guard let next = node.children.first(where: { $0.name == comp }) else { return nil }
            chain.append(next)
            node = next
        }
        return (node, chain)
    }

    private func expand(_ path: String) {
        guard flat == nil, let (_, chain) = node(path) else { return }
        for n in chain { outline.expandItem(n) }
    }

    /// Selects and reveals a file (or folder) without opening it again.
    func reveal(_ path: String) {
        guard flat == nil, let (node, chain) = node(path) else { return }
        for n in chain.dropLast() { outline.expandItem(n) }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        suppress = true
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        suppress = false
    }

    private func applyFilter() {
        let q = filter.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        flat = q.isEmpty ? nil : rankFuzzy(q, all).prefix(500).map { Node(name: $0, path: $0, isDir: false) }
        outline.reloadData()
    }

    func controlTextDidChange(_ obj: Notification) { applyFilter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)), let first = flat?.first {
            delegate?.navigatorOpen(path: first.path, line: nil)
            delegate?.navigatorFocusReader()
            return true
        }
        if sel == #selector(NSResponder.moveDown(_:)) {
            view.window?.makeFirstResponder(outline)
            if outline.selectedRow < 0, outline.numberOfRows > 0 { outline.selectRowIndexes([0], byExtendingSelection: false) }
            return true
        }
        return false
    }

    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let flat { return item == nil ? flat.count : 0 }
        return ((item as? Node) ?? root).children.count
    }

    func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let flat { return flat[index] }
        return ((item as? Node) ?? root).children[index]
    }

    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? Node)?.isDir == true }

    func outlineView(_ o: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? Node else { return nil }
        let id = NSUserInterfaceItemIdentifier("TreeCell")
        let cell = (o.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = id
            let img = NSImageView(), tf = NSTextField(labelWithString: ""), badge = NSTextField(labelWithString: "")
            for v in [img, tf, badge] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; c.addSubview(v) }
            tf.lineBreakMode = .byTruncatingMiddle
            tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            badge.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
            badge.setContentHuggingPriority(.required, for: .horizontal)
            badge.tag = 7
            c.imageView = img
            c.textField = tf
            NSLayoutConstraint.activate([
                img.leadingAnchor.constraint(equalTo: c.leadingAnchor),
                img.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                img.widthAnchor.constraint(equalToConstant: 16),
                tf.leadingAnchor.constraint(equalTo: img.trailingAnchor, constant: 5),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                badge.leadingAnchor.constraint(greaterThanOrEqualTo: tf.trailingAnchor, constant: 4),
                badge.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -6),
                badge.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        cell.textField?.stringValue = n.name
        cell.imageView?.image = NSImage(systemSymbolName: n.isDir ? "folder" : "doc", accessibilityDescription: nil)
        let badge = cell.viewWithTag(7) as? NSTextField
        if let s = changed[n.path] {
            let (letter, color) = statusLetter(s)
            badge?.stringValue = letter
            badge?.textColor = color
        } else if n.isDir, changed.keys.contains(where: { $0.hasPrefix(n.path + "/") }) {
            badge?.stringValue = "•"
            badge?.textColor = .secondaryLabelColor
        } else {
            badge?.stringValue = ""
        }
        cell.toolTip = n.path
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppress, let n = outline.item(atRow: outline.selectedRow) as? Node, !n.isDir else { return }
        delegate?.navigatorOpen(path: n.path, line: nil)
    }
}

/// Returns the status letter and colour for a change, as shown in lists.
func statusLetter(_ status: Character) -> (String, NSColor) {
    switch status {
    case "A": ("A", .systemGreen)
    case "?": ("U", .systemGreen)
    case "D": ("D", .systemRed)
    case "R": ("R", .systemBlue)
    case "C": ("C", .systemBlue)
    case "T": ("T", .systemOrange)
    case "U": ("!", .systemRed)
    default: ("M", .systemOrange)
    }
}

/// Fuzzy-matches paths and ranks them like Open Quickly.
///
/// Contiguous and file-name matches come first.
func rankFuzzy(_ q: String, _ paths: [String]) -> [String] {
    let query = Array(q.lowercased())
    var scored: [(Int, String)] = []
    for p in paths {
        let lower = p.lowercased()
        let name = (lower as NSString).lastPathComponent
        var score: Int
        if name == q { score = 1000 }
        else if name.hasPrefix(q) { score = 800 }
        else if name.contains(q) { score = 600 }
        else if lower.contains(q) { score = 400 }
        else {
            var qi = 0, s = 0, prev: Character = "/"
            for c in lower where qi < query.count {
                if c == query[qi] {
                    s += "/_-. ".contains(prev) ? 10 : 1
                    qi += 1
                }
                prev = c
            }
            guard qi == query.count else { continue }
            score = s
        }
        scored.append((score * 1000 - min(999, p.count), p))
    }
    return scored.sorted { $0.0 > $1.0 }.map(\.1)
}

/// Text search results across the snapshot, grouped by file.
///
/// Also lists definitions and usages.
@MainActor
final class SearchController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
    final class Group {
        let path: String
        var matches: [GrepMatch]
        var definitionLines: Set<Int>
        init(path: String, matches: [GrepMatch], definitionLines: Set<Int>) { self.path = path; self.matches = matches; self.definitionLines = definitionLines }
    }
    final class Item {
        let group: Group
        let match: GrepMatch
        init(group: Group, match: GrepMatch) { self.group = group; self.match = match }
    }

    weak var delegate: NavigatorDelegate?
    let field = NSSearchField()
    let outline = NSOutlineView()
    let status = NSTextField(labelWithString: "")
    private var groups: [Group] = []
    private var items: [ObjectIdentifier: [Item]] = [:]
    private var query = ""
    var wholeWord = false
    var caseSensitive = false

    override func loadView() {
        let v = NSView()
        field.placeholderString = "Search"
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
        outline.style = .inset
        outline.rowHeight = 22
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked)
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
            let s = NSMutableAttributedString(string: (g.path as NSString).lastPathComponent, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)])
            let dir = (g.path as NSString).deletingLastPathComponent
            if !dir.isEmpty { s.append(NSAttributedString(string: "  " + dir, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])) }
            cell.textField?.attributedStringValue = s
            cell.toolTip = g.path
        } else if let it = item as? Item {
            let m = it.match
            let isDef = it.group.definitionLines.contains(m.line)
            let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: isDef ? .semibold : .regular)
            let s = NSMutableAttributedString(string: "\(m.line)  ", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor])
            var text = m.text.trimmingCharacters(in: .whitespaces) as NSString
            var r = text.range(of: query, options: caseSensitive ? [] : .caseInsensitive)
            if r.location != NSNotFound, r.location > 16 {
                let cut = r.location - 10
                text = ("…" + text.substring(from: cut)) as NSString
                r.location -= cut - 1
            }
            let start = s.length
            s.append(NSAttributedString(string: text as String, attributes: [.font: mono, .foregroundColor: NSColor.labelColor]))
            if r.location != NSNotFound {
                s.addAttribute(.backgroundColor, value: NSColor.findHighlightColor.withAlphaComponent(0.5), range: NSRange(location: start + r.location, length: r.length))
            }
            cell.textField?.attributedStringValue = s
            cell.toolTip = isDef ? "Definition" : nil
        }
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) { clicked() }

    @objc private func clicked() {
        guard let it = outline.item(atRow: outline.selectedRow) as? Item else { return }
        delegate?.navigatorOpen(path: it.group.path, line: it.match.line)
    }
}

extension SearchController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(withTitle: "Whole Words")?.state = wholeWord ? .on : .off
        menu.item(withTitle: "Match Case")?.state = caseSensitive ? .on : .off
    }
}

/// The review's notes.
///
/// Select one to go to it, or copy them all as Markdown to hand off.
@MainActor
final class NotesController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    weak var delegate: NavigatorDelegate?
    let table = KeyTableView()
    private let copyButton = NSButton(title: "Copy All", target: nil, action: nil)
    private let empty = NSTextField(labelWithString: "No notes")
    private(set) var notes: [Note] = []

    override func loadView() {
        let v = NSView()
        let col = NSTableColumn(identifier: .init("n"))
        table.addTableColumn(col)
        table.headerView = nil
        table.style = .inset
        table.usesAutomaticRowHeights = true
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.onDelete = { [weak self] in self?.deleteSelected() }
        table.menu = NSMenu()
        table.menu?.addItem(withTitle: "Copy as Markdown", action: #selector(copySelected), keyEquivalent: "").target = self
        table.menu?.addItem(withTitle: "Delete", action: #selector(deleteSelected), keyEquivalent: "").target = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        copyButton.target = self
        copyButton.action = #selector(copyAll)
        copyButton.controlSize = .regular
        copyButton.toolTip = "Copy every note as Markdown"
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        empty.textColor = .secondaryLabelColor
        empty.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(scroll)
        v.addSubview(copyButton)
        v.addSubview(empty)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: v.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: copyButton.topAnchor, constant: -8),
            copyButton.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),
            copyButton.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -10),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        view = v
    }

    func setNotes(_ n: [Note]) {
        notes = n.sorted { ($0.path, $0.lines.lowerBound) < ($1.path, $1.lines.lowerBound) }
        table.reloadData()
        empty.isHidden = !notes.isEmpty
        copyButton.isEnabled = !notes.isEmpty
    }

    func numberOfRows(in tableView: NSTableView) -> Int { notes.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("NoteCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = id
            let ref = NSTextField(labelWithString: ""), text = NSTextField(wrappingLabelWithString: "")
            ref.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            ref.textColor = .secondaryLabelColor
            ref.lineBreakMode = .byTruncatingHead
            ref.tag = 1
            text.maximumNumberOfLines = 3
            text.lineBreakMode = .byTruncatingTail
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            text.tag = 2
            for v in [ref, text] { v.translatesAutoresizingMaskIntoConstraints = false; c.addSubview(v) }
            NSLayoutConstraint.activate([
                ref.topAnchor.constraint(equalTo: c.topAnchor, constant: 5),
                ref.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                ref.trailingAnchor.constraint(lessThanOrEqualTo: c.trailingAnchor, constant: -4),
                text.topAnchor.constraint(equalTo: ref.bottomAnchor, constant: 2),
                text.leadingAnchor.constraint(equalTo: ref.leadingAnchor),
                text.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                text.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -5),
            ])
            return c
        }()
        let n = notes[row]
        (cell.viewWithTag(1) as? NSTextField)?.stringValue = n.reference
        (cell.viewWithTag(2) as? NSTextField)?.stringValue = n.text
        cell.toolTip = "\(n.reference)\n\(n.context)"
        return cell
    }

    @objc private func clicked() {
        let r = table.selectedRow
        guard r >= 0, r < notes.count, table.selectedRowIndexes.count == 1 else { return }
        delegate?.navigatorOpenNote(notes[r])
    }

    func tableViewSelectionDidChange(_ notification: Notification) { clicked() }

    private var selected: [Note] {
        let rows = table.clickedRow >= 0 && !table.selectedRowIndexes.contains(table.clickedRow) ? IndexSet(integer: table.clickedRow) : table.selectedRowIndexes
        return rows.compactMap { $0 < notes.count ? notes[$0] : nil }
    }

    @objc private func copyAll() { delegate?.navigatorCopyNotes(nil) }
    @objc private func copySelected() { delegate?.navigatorCopyNotes(selected) }
    @objc private func deleteSelected() {
        let ids = Set(selected.map(\.id))
        if !ids.isEmpty { delegate?.navigatorDeleteNotes(ids) }
    }
}
