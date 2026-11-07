import AppKit
import SextantCore

@MainActor
protocol InspectorDelegate: AnyObject {
    /// Asks to move the reader to a line of the file it shows, by index into its lines.
    func inspectorJump(toLineIndex index: Int)
    /// Asks the overview to move to a file, by its index among the changes.
    func inspectorShowChange(_ index: Int)
}

/// The right column, which explains what the reader shows: the file's outline with what the
/// change touched, its runs of changes, and what's being reviewed, with the review's notes
/// below.
///
/// It follows the caret, and clicking a row moves the reader there.
@MainActor
final class Inspector: NSViewController, NSSplitViewDelegate {
    final class Entry: NSObject {
        enum Kind {
            case section(String)
            case symbol(OutlineItem)
            case change(FileText.KeyedRun, enclosing: String?, read: Bool)
            case file(FileState, index: Int)
            case card(NSAttributedString)
            case message(String)
        }
        enum Shape { case section, card, row }
        var kind: Kind
        var children: [Entry]
        init(_ kind: Kind, children: [Entry] = []) { self.kind = kind; self.children = children }

        var sectionTitle: String? { if case .section(let t) = kind { t } else { nil } }

        /// The kind of cell and row height the entry needs.
        var shape: Shape {
            switch kind {
            case .section: .section
            case .card: .card
            default: .row
            }
        }

        /// Whether this entry's row can show another entry by changing its cell's contents.
        func fits(_ other: Entry) -> Bool { shape == other.shape && children.isEmpty == other.children.isEmpty }
    }

    weak var delegate: InspectorDelegate?
    let outline = KeyOutlineView()
    let notes = NotesPane()
    private let split = SeamlessSplitView()
    /// The entries the outline shows, under a root that stands for the outline itself.
    private let root = Entry(.section(""))
    private var sections: [Entry] { root.children }
    /// The file the focused pane shows by itself, with the text it shows, whose line indices the
    /// outline and changes follow.
    private var shown: ShownFile?
    private var items: [OutlineItem] = []
    private var files: [FileState] = []
    private var card: (title: String, text: NSAttributedString)?
    private var generation = 0
    private var suppress = false
    /// The sections the user folded, by title.
    private var folded: Set<String> = []
    /// Says whether a run of changes has been read.
    var isRead: (FileState, FileText.KeyedRun) -> Bool = { _, _ in false }
    private let look: any Look
    private lazy var rowViews = RowViews(look: look)

    init(look: any Look) {
        self.look = look
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    var changedOnly: Bool {
        get { UserDefaults.standard.bool(forKey: "outlineChangedOnly") }
        set { UserDefaults.standard.set(newValue, forKey: "outlineChangedOnly"); rebuild() }
    }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("entry"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.backgroundColor = .clear
        outline.usesAutomaticRowHeights = false
        outline.indentationPerLevel = 10
        outline.autoresizesOutlineColumn = false
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked)
        outline.setAccessibilityLabel("Inspector")
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        addChild(notes)
        split.isVertical = false
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(scroll)
        split.addArrangedSubview(notes.view)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 1)
        split.autosaveName = "SextantInspectorSplit"
        view = split
    }

    private var placedDivider = false

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !placedDivider, split.bounds.height > 0 else { return }
        placedDivider = true
        if UserDefaults.standard.object(forKey: "NSSplitView Subview Frames SextantInspectorSplit") == nil {
            split.setPosition(split.bounds.height * 0.6, ofDividerAt: 0)
        }
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { 120 }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        splitView.bounds.height - 90
    }

    /// Shows the outline and changes of the file the focused pane shows by itself, with the
    /// outline once the text is analyzed.
    func showFile(_ s: ShownFile, card: (title: String, text: NSAttributedString)?) {
        let isNew = s.text !== shown?.text
        shown = s
        files = []
        self.card = card
        generation += 1
        let gen = generation
        let t = s.text
        if isNew || t.outline != nil { items = t.outline ?? [] }
        rebuild()
        guard t.outline == nil, t.hasLanguage, t.hasTags != false, !s.file.diff.isBinary else { return }
        Task {
            await t.analyze(symbols: true)
            guard gen == generation, let outline = t.outline else { return }
            items = outline
            rebuild()
        }
    }

    /// Shows the overview's files as a table of contents.
    func showOverview(_ changes: [FileState], card: (title: String, text: NSAttributedString)?) {
        shown = nil
        files = changes
        items = []
        self.card = card
        generation += 1
        rebuild()
    }

    func showEmpty(card: (title: String, text: NSAttributedString)?) {
        shown = nil
        files = []
        items = []
        self.card = card
        generation += 1
        rebuild()
    }

    func updateCard(_ card: (title: String, text: NSAttributedString)?) {
        self.card = card
        rebuild()
    }

    func refreshReviewState() {
        guard !files.isEmpty || shown?.file.isChange == true else { return }
        rebuild()
    }

    private func rebuild() {
        var out: [Entry] = []
        if let s = shown {
            let t = s.text
            if s.file.isChange, !t.keyedRuns.isEmpty {
                let flat = flatten(items)
                out.append(Entry(.section("Changes"), children: t.keyedRuns.map { r in
                    Entry(.change(r, enclosing: flat.last { $0.change != .deleted && $0.span.contains(r.run.newLine) }?.name, read: isRead(s.file, r)))
                }))
            }
            if t.hasLanguage, t.hasTags != false {
                let listed = changedOnly ? pruned(items) : items
                let entries = listed.map(entry)
                out.append(Entry(.section("Outline"), children: entries.isEmpty ? [Entry(.message(items.isEmpty ? "No definitions" : "No changed definitions"))] : entries))
            }
        } else if !files.isEmpty {
            out.append(Entry(.section("Files"), children: files.indices.map { Entry(.file(files[$0], index: $0)) }))
        }
        if let card { out.append(Entry(.section(card.title), children: [Entry(.card(card.text))])) }
        show(out)
        if let caret = lastCaret { follow(lineIndex: caret) }
    }

    /// Shows new entries by changing the rows already made, and inserting or removing only the
    /// difference, since making row views costs more than everything else in an update.
    private func show(_ fresh: [Entry]) {
        suppress = true
        merge(fresh, into: root)
        expandSections()
        outline.enumerateAvailableRowViews { _, row in
            guard let e = outline.item(atRow: row) as? Entry,
                  let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView else { return }
            configure(cell, as: e)
        }
        let cards = IndexSet((0..<outline.numberOfRows).filter { (outline.item(atRow: $0) as? Entry)?.shape == .card })
        if !cards.isEmpty { outline.noteHeightOfRows(withIndexesChanged: cards) }
        suppress = false
    }

    /// Makes a parent's children match fresh entries, keeping each existing entry the fresh one
    /// at its position fits, so its row stays.
    private func merge(_ fresh: [Entry], into parent: Entry) {
        guard !(parent.children.isEmpty && fresh.isEmpty) else { return }
        let item: Entry? = parent === root ? nil : parent
        guard item.map(outline.isItemExpanded) ?? true else {
            parent.children = fresh
            outline.reloadItem(item, reloadChildren: true)
            return
        }
        let old = parent.children
        let shared = min(old.count, fresh.count)
        let replaced = IndexSet((0..<shared).filter { !old[$0].fits(fresh[$0]) })
        let removed = replaced.union(IndexSet(shared..<old.count))
        let inserted = replaced.union(IndexSet(shared..<fresh.count))
        if !removed.isEmpty || !inserted.isEmpty {
            outline.beginUpdates()
            parent.children = old.indices.filter { !removed.contains($0) }.map { old[$0] }
            outline.removeItems(at: removed, inParent: item)
            parent.children = fresh.indices.map { inserted.contains($0) ? fresh[$0] : old[$0] }
            outline.insertItems(at: inserted, inParent: item)
            outline.endUpdates()
        }
        for i in (0..<shared) where !replaced.contains(i) {
            old[i].kind = fresh[i].kind
            merge(fresh[i].children, into: old[i])
        }
    }

    /// Expands every entry with children, except sections the user folded.
    ///
    /// Expands a whole section at once when anything in it is collapsed, since the outline
    /// updates its rows once per call, and a long file has thousands of entries to expand.
    private func expandSections() {
        for section in root.children where !section.children.isEmpty {
            if let title = section.sectionTitle, folded.contains(title) {
                outline.collapseItem(section)
            } else if hasCollapsed(section) {
                outline.expandItem(section, expandChildren: true)
            }
        }
    }

    private func hasCollapsed(_ e: Entry) -> Bool {
        !e.children.isEmpty && (!outline.isItemExpanded(e) || e.children.contains(where: hasCollapsed))
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !suppress, let title = (notification.userInfo?["NSObject"] as? Entry)?.sectionTitle else { return }
        folded.insert(title)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !suppress, let title = (notification.userInfo?["NSObject"] as? Entry)?.sectionTitle else { return }
        folded.remove(title)
    }

    private func entry(_ i: OutlineItem) -> Entry {
        Entry(.symbol(i), children: (changedOnly ? pruned(i.children) : i.children).map(entry))
    }

    private func pruned(_ items: [OutlineItem]) -> [OutlineItem] {
        items.filter(\.isTouched).map { var c = $0; c.children = pruned(c.children); return c }
    }

    private func flatten(_ items: [OutlineItem]) -> [OutlineItem] { items.flatMap { [$0] + flatten($0.children) } }

    private var lastCaret: Int?

    /// Highlights the definition and change at a line of the file, by index into its lines, or
    /// the file at that index in the overview.
    func follow(lineIndex: Int?) {
        lastCaret = lineIndex
        guard let lineIndex else { return }
        var rows = IndexSet()
        if !files.isEmpty {
            if let e = sections.first?.children.first(where: { if case .file(_, let i) = $0.kind { i == lineIndex } else { false } }) {
                rows.insert(outline.row(forItem: e))
            }
        } else if let t = shown?.text, t.lines.indices.contains(lineIndex) {
            let line = t.lines[lineIndex]
            let newLine = line.kind == .deleted ? nil : line.newNo - 1
            func innermost(_ entries: [Entry]) -> Entry? {
                for e in entries {
                    guard case .symbol(let s) = e.kind else { continue }
                    let hit = s.change == .deleted ? (line.kind == .deleted && line.oldNo - 1 == s.line) : newLine.map { s.span.contains($0) } ?? false
                    if hit { return innermost(e.children) ?? e }
                }
                return nil
            }
            for section in sections {
                if case .section("Outline") = section.kind, let e = innermost(section.children) { rows.insert(outline.row(forItem: e)) }
                if case .section("Changes") = section.kind, let e = section.children.first(where: {
                    if case .change(let r, _, _) = $0.kind { r.run.lines.contains(lineIndex) } else { false }
                }) {
                    rows.insert(outline.row(forItem: e))
                }
            }
        }
        rows.remove(-1)
        suppress = true
        outline.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first, outline.window?.firstResponder !== outline { outline.scrollRowToVisible(first) }
        suppress = false
    }

    @objc private func clicked() {
        guard let e = outline.item(atRow: outline.clickedRow) as? Entry else { return }
        activate(e)
    }

    private func activate(_ e: Entry) {
        switch e.kind {
        case .symbol(let s):
            guard let t = shown?.text, let i = t.index(ofLine: s.line + 1, old: s.change == .deleted) else { return }
            delegate?.inspectorJump(toLineIndex: i)
        case .change(let r, _, _): delegate?.inspectorJump(toLineIndex: r.run.lines.lowerBound)
        case .file(_, let i): delegate?.inspectorShowChange(i)
        default: break
        }
    }

    @objc private func toggleChangedOnly(_ sender: NSButton) { changedOnly = sender.state == .on }
}

extension Inspector: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { rowViews.next() }

    func outlineView(_ outlineView: NSOutlineView, didRemove rowView: NSTableRowView, forRow row: Int) { rowViews.removed(rowView) }

    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? Entry) ?? root).children.count
    }

    func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? Entry) ?? root).children[index]
    }

    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { !((item as? Entry)?.children.isEmpty ?? true) }

    func outlineView(_ o: NSOutlineView, isGroupItem item: Any) -> Bool { false }

    /// Gives rows fixed heights, and the card the height of its text, so rebuilding the outline
    /// doesn't lay out every row to measure it.
    func outlineView(_ o: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let e = item as? Entry else { return 24 }
        switch e.kind {
        case .section: return 28
        case .card(let text):
            let column = o.tableColumns.first?.width ?? o.bounds.width
            let width = max(80, column - o.indentationPerLevel * CGFloat(max(0, o.level(forItem: item))) - 14)
            let bounds = text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
            return ceil(bounds.height) + 14
        default: return 24
        }
    }

    func outlineViewColumnDidResize(_ notification: Notification) {
        let cards = IndexSet((0..<outline.numberOfRows).filter { r in
            if case .card? = (outline.item(atRow: r) as? Entry)?.kind { true } else { false }
        })
        if !cards.isEmpty { outline.noteHeightOfRows(withIndexesChanged: cards) }
    }

    func outlineView(_ o: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let e = item as? Entry else { return false }
        switch e.kind {
        case .symbol, .change, .file: return true
        default: return false
        }
    }

    func outlineView(_ o: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let e = item as? Entry else { return nil }
        let cell: NSTableCellView = switch e.shape {
        case .section: InspectorSectionCell.make(o)
        case .card: InspectorCardCell()
        case .row: InspectorRowCell.make(o)
        }
        configure(cell, as: e)
        return cell
    }

    /// Shows an entry in a cell of its shape, whether new or already on screen.
    private func configure(_ view: NSTableCellView, as e: Entry) {
        if let cell = view as? InspectorSectionCell, case .section(let title) = e.kind {
            cell.title.stringValue = title
            cell.hideToggle()
            if title == "Outline" {
                cell.toggle.isHidden = false
                cell.toggle.state = changedOnly ? .on : .off
                cell.toggle.contentTintColor = changedOnly ? .themed("accent") : .themed("fgMuted")
                cell.toggle.target = self
                cell.toggle.action = #selector(toggleChangedOnly(_:))
            }
        } else if let cell = view as? InspectorCardCell, case .card(let text) = e.kind {
            cell.text.attributedStringValue = text
        } else if let cell = view as? InspectorRowCell {
            cell.toolTip = nil
            cell.setAccessibilityValue(nil)
            configure(cell, as: e.kind)
        }
    }

    private func configure(_ cell: InspectorRowCell, as kind: Entry.Kind) {
        switch kind {
        case .symbol(let s):
            let attrs: [NSAttributedString.Key: Any] = s.change == .deleted
                ? [.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.themed("fgMuted")]
                : [.foregroundColor: NSColor.themed("fg")]
            cell.set(symbol: symbolImage(s.kind), title: NSAttributedString(string: s.name, attributes: attrs.merging([.font: NSFont.row]) { $1 }),
                     marker: s.change)
            cell.toolTip = "\(s.kind) \(s.name)" + (s.change == .none ? "" : " (\(s.change))")
        case .change(let keyed, let enclosing, let read):
            let r = keyed.run
            let t = NSMutableAttributedString(string: changeTitle(r), attributes: [.font: NSFont.row, .foregroundColor: read ? NSColor.themed("fgMuted") : NSColor.themed("fg")])
            if r.additions > 0 { t.append(NSAttributedString(string: "  +\(r.additions)", attributes: [.foregroundColor: NSColor.themed("success"), .font: NSFont.detailDigits])) }
            if r.deletions > 0 { t.append(NSAttributedString(string: "  −\(r.deletions)", attributes: [.foregroundColor: NSColor.themed("danger"), .font: NSFont.detailDigits])) }
            if let enclosing { t.append(NSAttributedString(string: "  " + enclosing, attributes: [.foregroundColor: NSColor.themed("fgMuted"), .font: NSFont.detail])) }
            cell.set(symbol: read ? "checkmark.circle.fill" : "plusminus", title: t, marker: .none)
            cell.setAccessibilityValue(read ? "Read" : "Not read")
        case .file(let f, _):
            let t = NSMutableAttributedString(string: (f.path as NSString).lastPathComponent, attributes: [.font: NSFont.row, .foregroundColor: f.reviewed ? NSColor.themed("fgMuted") : NSColor.themed("fg")])
            t.append(NSAttributedString(string: "  +\(f.diff.additions)", attributes: [.foregroundColor: NSColor.themed("success"), .font: NSFont.detailDigits]))
            t.append(NSAttributedString(string: " −\(f.diff.deletions)", attributes: [.foregroundColor: NSColor.themed("danger"), .font: NSFont.detailDigits]))
            cell.set(image: fileIcon(f.path), title: t)
            cell.toolTip = f.path
        case .section, .card: break
        case .message(let m):
            cell.set(symbol: nil, title: NSAttributedString(string: m, attributes: [.foregroundColor: NSColor.themed("fgMuted"), .font: NSFont.row]), marker: .none)
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppress, outline.window?.firstResponder === outline, outline.selectedRowIndexes.count == 1,
              let e = outline.item(atRow: outline.selectedRow) as? Entry else { return }
        activate(e)
    }

    private func changeTitle(_ r: ChangeRun) -> String {
        if r.additions == 0 { return "Removed at line \(r.newLine + 1)" }
        return r.additions == 1 ? "Line \(r.newLine + 1)" : "Lines \(r.newLine + 1)–\(r.newLine + r.additions)"
    }
}

/// The SF Symbol for a kind of definition.
func symbolImage(_ kind: String) -> String {
    switch kind {
    case "class", "struct", "type", "interface", "enum", "trait", "protocol", "union", "object", "mixin": "cube"
    case "module", "namespace", "impl", "extension": "shippingbox"
    case "method", "function", "operator": "function"
    case "constructor": "hammer"
    case "constant", "variable", "field", "property", "enum_variant": "character.textbox"
    case "macro": "wand.and.stars"
    case "test": "checkmark.diamond"
    case "heading": "textformat.size"
    case "table": "tablecells"
    case "view": "eye"
    case "index": "list.number"
    case "target": "target"
    case "anchor": "link"
    case "keyframes": "film"
    case "fragment": "puzzlepiece"
    case "directive": "at"
    default: "number"
    }
}

@MainActor
final class InspectorSectionCell: NSTableCellView {
    let title = NSTextField(labelWithString: "")
    private var madeToggle: NSButton?
    static let id = NSUserInterfaceItemIdentifier("InspectorSection")

    /// Returns a section cell, reused when the outline has one spare.
    static func make(_ o: NSOutlineView) -> InspectorSectionCell {
        (o.makeView(withIdentifier: id, owner: nil) as? InspectorSectionCell) ?? InspectorSectionCell()
    }

    /// Hides the toggle, which a section shows by unhiding it afterwards.
    func hideToggle() {
        madeToggle?.isHidden = true
        needsLayout = true
    }

    init() {
        super.init(frame: .zero)
        identifier = InspectorSectionCell.id
        title.font = .sectionLabel
        title.textColor = .themed("fgMuted")
        addSubview(title)
        textField = title
    }

    /// The Changed Only toggle, a filter icon that fills while it's on, made when a section first
    /// shows it, since only one does.
    var toggle: NSButton {
        if let t = madeToggle { return t }
        let t = NSButton(image: NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: "Changed Only")!, target: nil, action: nil)
        t.alternateImage = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle.fill", accessibilityDescription: "Changed Only")
        t.setButtonType(.toggle)
        t.isBordered = false
        t.symbolConfiguration = .init(textStyle: .body, scale: .medium)
        t.toolTip = "Show Only Definitions the Change Touched"
        addSubview(t)
        madeToggle = t
        return t
    }

    private static var toggleSize: NSSize?

    /// Lays out by frame, since constraints make every new row cost a layout pass.
    override func layout() {
        super.layout()
        let h = bounds.height
        var right = bounds.width - 2
        if let t = madeToggle, !t.isHidden {
            let size = InspectorSectionCell.toggleSize ?? t.intrinsicContentSize
            InspectorSectionCell.toggleSize = size
            t.frame = NSRect(x: bounds.width - 6 - size.width, y: round((h - size.height) / 2) - 1, width: size.width, height: size.height)
            right = t.frame.minX - 6
        }
        let th = title.intrinsicContentSize.height
        title.frame = textFieldFrame(NSRect(x: 2, y: round((h - th) / 2) - 1, width: max(0, right - 2), height: th))
    }

    required init?(coder: NSCoder) { fatalError() }
}

@MainActor
final class InspectorRowCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("InspectorRow")
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let marker = ChangeMarker()

    static func make(_ o: NSOutlineView) -> InspectorRowCell {
        (o.makeView(withIdentifier: id, owner: nil) as? InspectorRowCell) ?? InspectorRowCell()
    }

    init() {
        super.init(frame: .zero)
        identifier = InspectorRowCell.id
        icon.symbolConfiguration = .init(textStyle: .body, scale: .small)
        icon.contentTintColor = .themed("fgMuted")
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.usesSingleLineMode = true
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(icon)
        addSubview(title)
        addSubview(marker)
        textField = title
    }

    /// Lays out by frame, since constraints make every new row cost a layout pass.
    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: 2, y: round((h - 16) / 2), width: 16, height: 16)
        marker.frame = NSRect(x: bounds.width - 14, y: round((h - 6) / 2), width: 6, height: 6)
        let t = title.intrinsicContentSize.height
        title.frame = textFieldFrame(NSRect(x: 23, y: round((h - t) / 2), width: max(0, marker.frame.minX - 6 - 23), height: t))
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(symbol: String?, title t: NSAttributedString, marker change: OutlineItem.Change) {
        icon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        icon.isHidden = symbol == nil
        title.attributedStringValue = truncating(t)
        let color: NSColor? = switch change {
        case .none: nil
        case .modified: .themed("attention")
        case .added: .themed("success")
        case .deleted: .themed("danger")
        }
        marker.isHidden = color == nil
        marker.color = color
        marker.setAccessibilityLabel(color == nil ? nil : "\(change)")
    }

    /// Keeps a row to one line, cutting its end off when it doesn't fit.
    private func truncating(_ t: NSAttributedString) -> NSAttributedString {
        let s = NSMutableAttributedString(attributedString: t)
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        s.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: s.length))
        return s
    }

    func set(image: NSImage, title t: NSAttributedString) {
        icon.image = image
        icon.isHidden = false
        title.attributedStringValue = truncating(t)
        marker.isHidden = true
    }
}

/// The dot at the end of an inspector row that says how a definition changed, in a colour
/// resolved each time it's drawn, so it follows the appearance and theme.
@MainActor
private final class ChangeMarker: NSView {
    var color: NSColor? { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 3
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = color?.cgColor
    }
}

@MainActor
final class InspectorCardCell: NSTableCellView {
    let text = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        text.isSelectable = true
        text.translatesAutoresizingMaskIntoConstraints = false
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.preferredMaxLayoutWidth = 200
        addSubview(text)
        textField = text
        NSLayoutConstraint.activate([
            text.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        text.preferredMaxLayoutWidth = max(80, bounds.width - 10)
    }
}
