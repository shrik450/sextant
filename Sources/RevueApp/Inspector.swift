import AppKit
import RevueCore

@MainActor
protocol InspectorDelegate: AnyObject {
    /// Asks to move the reader to a line of the file it shows, by index into its lines.
    func inspectorJump(toLineIndex index: Int)
    /// Asks the overview to move to a file, by its index among the changes.
    func inspectorShowChange(_ index: Int)
}

/// The right column, which explains what the reader shows: the file's outline with what the
/// change touched, its runs of changes, and what's being reviewed.
///
/// It follows the caret, and clicking a row moves the reader there.
@MainActor
final class Inspector: NSViewController {
    final class Entry {
        enum Kind {
            case section(String)
            case symbol(OutlineItem)
            case change(ChangeRun, enclosing: String?)
            case file(FileState, index: Int)
            case card(NSAttributedString)
            case message(String)
        }
        let kind: Kind
        var children: [Entry]
        init(_ kind: Kind, children: [Entry] = []) { self.kind = kind; self.children = children }

        var isSection: Bool { if case .section = kind { true } else { false } }
    }

    weak var delegate: InspectorDelegate?
    let outline = NSOutlineView()
    private var sections: [Entry] = []
    private var file: FileState?
    private var items: [OutlineItem] = []
    private var runs: [ChangeRun] = []
    private var files: [FileState] = []
    private var card: (title: String, text: NSAttributedString)?
    private var generation = 0
    private var suppress = false

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
        outline.floatsGroupRows = false
        outline.usesAutomaticRowHeights = true
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
        view = scroll
    }

    /// Shows a file's outline and changes, working the outline out in the background.
    func showFile(_ f: FileState, card: (title: String, text: NSAttributedString)?) {
        let isNew = f !== file
        file = f
        files = []
        self.card = card
        runs = f.isChange ? changeRuns(f.lines) : []
        generation += 1
        let gen = generation
        if isNew { items = [] }
        rebuild()
        guard let lang = f.language, lang.hasTags, !f.diff.isBinary else { return }
        let lines = f.lines
        let new = f.sideText(old: false).joined(separator: "\n")
        let old = f.isChange && f.hasOldSide ? f.sideText(old: true).joined(separator: "\n") : nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                let newDefs = lang.symbols(new).filter(\.isDefinition)
                let oldDefs = old.map { lang.symbols($0).filter(\.isDefinition) } ?? newDefs
                return RevueCore.outline(lines: lines, new: newDefs, old: oldDefs)
            }.value
            guard gen == generation else { return }
            items = result
            rebuild()
        }
    }

    /// Shows the overview's files as a table of contents.
    func showOverview(_ changes: [FileState], card: (title: String, text: NSAttributedString)?) {
        file = nil
        files = changes
        items = []
        runs = []
        self.card = card
        generation += 1
        rebuild()
    }

    func showEmpty(card: (title: String, text: NSAttributedString)?) {
        file = nil
        files = []
        items = []
        runs = []
        self.card = card
        generation += 1
        rebuild()
    }

    func updateCard(_ card: (title: String, text: NSAttributedString)?) {
        self.card = card
        rebuild()
    }

    func refreshReviewState() {
        guard !files.isEmpty else { return }
        rebuild()
    }

    private func rebuild() {
        var out: [Entry] = []
        if let f = file {
            if f.language?.hasTags == true {
                let shown = changedOnly ? pruned(items) : items
                let entries = shown.map(entry)
                out.append(Entry(.section("Outline"), children: entries.isEmpty ? [Entry(.message(items.isEmpty ? "No definitions" : "No changed definitions"))] : entries))
            }
            if f.isChange, !runs.isEmpty {
                let flat = flatten(items)
                out.append(Entry(.section("Changes"), children: runs.map { r in
                    Entry(.change(r, enclosing: flat.last { $0.change != .deleted && $0.span.contains(r.newLine) }?.name))
                }))
            }
        } else if !files.isEmpty {
            out.append(Entry(.section("Files"), children: files.indices.map { Entry(.file(files[$0], index: $0)) }))
        }
        if let card { out.append(Entry(.section(card.title), children: [Entry(.card(card.text))])) }
        sections = out
        suppress = true
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        suppress = false
        if let caret = lastCaret { follow(lineIndex: caret) }
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
        } else if let f = file, f.lines.indices.contains(lineIndex) {
            let line = f.lines[lineIndex]
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
                    if case .change(let r, _) = $0.kind { r.lines.contains(lineIndex) } else { false }
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
            guard let f = file, let i = f.index(ofLine: s.line + 1, old: s.change == .deleted) else { return }
            delegate?.inspectorJump(toLineIndex: i)
        case .change(let r, _): delegate?.inspectorJump(toLineIndex: r.lines.lowerBound)
        case .file(_, let i): delegate?.inspectorShowChange(i)
        default: break
        }
    }

    @objc private func toggleChangedOnly(_ sender: NSButton) { changedOnly = sender.state == .on }
}

extension Inspector: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Entry)?.children.count ?? sections.count
    }

    func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Entry)?.children[index] ?? sections[index]
    }

    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { !((item as? Entry)?.children.isEmpty ?? true) }

    func outlineView(_ o: NSOutlineView, isGroupItem item: Any) -> Bool { (item as? Entry)?.isSection == true }

    func outlineView(_ o: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let e = item as? Entry else { return false }
        switch e.kind {
        case .symbol, .change, .file: return true
        default: return false
        }
    }

    func outlineView(_ o: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let e = item as? Entry else { return nil }
        switch e.kind {
        case .section(let title):
            let cell = InspectorSectionCell()
            cell.title.stringValue = title
            if title == "Outline" {
                cell.toggle.isHidden = false
                cell.toggle.state = changedOnly ? .on : .off
                cell.toggle.target = self
                cell.toggle.action = #selector(toggleChangedOnly(_:))
            }
            return cell
        case .symbol(let s):
            let cell = InspectorRowCell.make(o)
            let attrs: [NSAttributedString.Key: Any] = s.change == .deleted
                ? [.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.secondaryLabelColor]
                : [.foregroundColor: NSColor.labelColor]
            cell.set(symbol: symbolImage(s.kind), title: NSAttributedString(string: s.name, attributes: attrs.merging([.font: NSFont.systemFont(ofSize: 12)]) { $1 }),
                     marker: s.change)
            cell.toolTip = "\(s.kind) \(s.name)" + (s.change == .none ? "" : " (\(s.change))")
            return cell
        case .change(let r, let enclosing):
            let cell = InspectorRowCell.make(o)
            let t = NSMutableAttributedString(string: changeTitle(r), attributes: [.font: NSFont.systemFont(ofSize: 12)])
            if r.additions > 0 { t.append(NSAttributedString(string: "  +\(r.additions)", attributes: [.foregroundColor: NSColor.systemGreen, .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)])) }
            if r.deletions > 0 { t.append(NSAttributedString(string: "  −\(r.deletions)", attributes: [.foregroundColor: NSColor.systemRed, .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)])) }
            if let enclosing { t.append(NSAttributedString(string: "  " + enclosing, attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 11)])) }
            cell.set(symbol: "plusminus", title: t, marker: .none)
            return cell
        case .file(let f, _):
            let cell = InspectorRowCell.make(o)
            let t = NSMutableAttributedString(string: (f.path as NSString).lastPathComponent, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: f.reviewed ? NSColor.secondaryLabelColor : NSColor.labelColor])
            t.append(NSAttributedString(string: "  +\(f.diff.additions)", attributes: [.foregroundColor: NSColor.systemGreen, .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)]))
            t.append(NSAttributedString(string: " −\(f.diff.deletions)", attributes: [.foregroundColor: NSColor.systemRed, .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)]))
            cell.set(image: fileIcon(f.path), title: t)
            cell.toolTip = f.path
            return cell
        case .card(let text):
            let cell = InspectorCardCell()
            cell.text.attributedStringValue = text
            return cell
        case .message(let m):
            let cell = InspectorRowCell.make(o)
            cell.set(symbol: nil, title: NSAttributedString(string: m, attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 12)]), marker: .none)
            return cell
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
    case "class", "struct", "type", "interface", "enum", "trait", "protocol": "cube"
    case "module", "namespace", "impl": "shippingbox"
    case "method", "function": "function"
    case "constant", "variable", "field", "property": "character.textbox"
    default: "number"
    }
}

@MainActor
final class InspectorSectionCell: NSTableCellView {
    let title = NSTextField(labelWithString: "")
    let toggle = NSButton(title: "Changed Only", target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        toggle.setButtonType(.pushOnPushOff)
        toggle.bezelStyle = .inline
        toggle.controlSize = .mini
        toggle.font = .systemFont(ofSize: 10)
        toggle.isHidden = true
        toggle.toolTip = "Show only definitions the change touched"
        for v in [title, toggle] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        textField = title
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            title.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            toggle.centerYAnchor.constraint(equalTo: title.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

@MainActor
final class InspectorRowCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("InspectorRow")
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let marker = NSView()

    static func make(_ o: NSOutlineView) -> InspectorRowCell {
        (o.makeView(withIdentifier: id, owner: nil) as? InspectorRowCell) ?? InspectorRowCell()
    }

    init() {
        super.init(frame: .zero)
        identifier = InspectorRowCell.id
        icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.usesSingleLineMode = true
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        marker.wantsLayer = true
        marker.layer?.cornerRadius = 3
        for v in [icon, title, marker] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        textField = title
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: marker.leadingAnchor, constant: -6),
            marker.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            marker.centerYAnchor.constraint(equalTo: centerYAnchor),
            marker.widthAnchor.constraint(equalToConstant: 6),
            marker.heightAnchor.constraint(equalToConstant: 6),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(symbol: String?, title t: NSAttributedString, marker change: OutlineItem.Change) {
        icon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        icon.isHidden = symbol == nil
        title.attributedStringValue = truncating(t)
        let color: NSColor? = switch change {
        case .none: nil
        case .modified: .systemOrange
        case .added: .systemGreen
        case .deleted: .systemRed
        }
        marker.isHidden = color == nil
        marker.layer?.backgroundColor = color?.cgColor
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
