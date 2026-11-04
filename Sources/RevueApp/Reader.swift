import AppKit
import RevueCore

@MainActor
protocol ReaderDelegate: AnyObject {
    func readerOpenFile(_ file: Int, line: Int?)
    func readerUnfolded()
    func readerJumpToDefinition(_ word: String, file: Int, line: Int)
    func readerEditNote(_ id: UUID)
    func readerMenu(file: Int?, line: Int?) -> NSMenu?
    func readerCurrentFileChanged()
    func readerBlameClicked(_ commit: Blame.Commit, line: Int)
}

/// Where the reader is, as a file and the line of it that is at the top (or selected).
struct ReaderPosition: Equatable {
    var file: Int
    /// The index into the file's lines.
    var line: Int
}

/// The code reader, showing one file or every changed file as an overview, in one or two columns.
@MainActor
final class Reader: NSViewController, CodeViewDelegate {
    weak var delegate: ReaderDelegate?

    private(set) var files: [FileState] = []
    private(set) var overview = false
    var notes: [Note] = []
    var split = false
    var showAll = false
    var wraps = false { didSet { columns.forEach { $0.code.wraps = wraps } } }
    var blame: Blame? { didSet { columns.forEach { $0.gutter.blame = blame; $0.gutter.updateThickness() } } }

    private struct Column {
        let scroll: NSScrollView
        let code: CodeView
        let gutter: Gutter
    }
    private var columns: [Column] = []
    private let stack = NSStackView()
    let jumpBar = JumpBar()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var layout = Layout(left: [], right: nil)
    private var syncing = false

    override func loadView() {
        let v = NSView()
        jumpBar.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .systemFont(ofSize: 15)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        v.addSubview(stack)
        v.addSubview(jumpBar)
        v.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            jumpBar.topAnchor.constraint(equalTo: v.safeAreaLayoutGuide.topAnchor),
            jumpBar.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            jumpBar.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            stack.topAnchor.constraint(equalTo: jumpBar.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: stack.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: stack.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, multiplier: 0.8),
        ])
        view = v
        setColumnCount(1)
        NotificationCenter.default.addObserver(self, selector: #selector(appearanceChanged), name: Appearance.didChange, object: nil)
        appearanceObservation = v.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.appearanceChanged() }
        }
    }

    private var appearanceObservation: NSKeyValueObservation?

    @objc private func appearanceChanged() {
        guard !files.isEmpty else { return }
        reload(keepPosition: true)
    }

    private func setColumnCount(_ n: Int) {
        guard columns.count != n else { return }
        for c in columns { c.scroll.removeFromSuperview() }
        columns = (0..<n).map { i in
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true
            scroll.autohidesScrollers = true
            scroll.findBarPosition = .aboveContent
            let code = CodeView.make()
            code.side = n == 2 ? i : 0
            code.codeDelegate = self
            scroll.documentView = code
            let gutter = Gutter(code: code, scrollView: scroll)
            scroll.verticalRulerView = gutter
            scroll.hasVerticalRuler = true
            scroll.rulersVisible = true
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            gutter.onBlameClick = { [weak self] c, line in self?.delegate?.readerBlameClicked(c, line: line) }
            stack.addArrangedSubview(scroll)
            return Column(scroll: scroll, code: code, gutter: gutter)
        }
        for c in columns { c.code.wraps = wraps; c.gutter.blame = blame }
        linkKeyLoop()
        view.layoutSubtreeIfNeeded()
    }

    /// Where Tab goes after the code (the last column).
    weak var keyLoopNext: NSView? { didSet { linkKeyLoop() } }
    /// Where Tab enters the code.
    var firstKeyView: NSView { columns.first!.code }

    private func linkKeyLoop() {
        for (i, c) in columns.enumerated() {
            c.code.nextKeyView = i + 1 < columns.count ? columns[i + 1].code : keyLoopNext
        }
    }

    /// The column with keyboard focus, else the new side.
    var activeCode: CodeView {
        columns.first { $0.code.window?.firstResponder === $0.code }?.code ?? columns.last!.code
    }

    func show(files: [FileState], overview: Bool, at position: ReaderPosition? = nil) {
        self.files = files
        self.overview = overview
        reload(keepPosition: false)
        if let position { scroll(to: position, animated: false) } else { scrollToTop() }
        for f in files where f.tokens == nil && f.language != nil {
            Task {
                await f.highlight()
                guard self.files.contains(where: { $0 === f }) else { return }
                self.scheduleRerender()
            }
        }
    }

    private var rerenderPending = false
    private func scheduleRerender() {
        guard !rerenderPending else { return }
        rerenderPending = true
        DispatchQueue.main.async {
            self.rerenderPending = false
            self.reload(keepPosition: true)
        }
    }

    func showEmpty(_ message: String) {
        files = []
        layout = Layout(left: [], right: nil)
        for c in columns { c.code.setContent(RenderedText(string: NSAttributedString(), rowStarts: []), rows: [], files: []) }
        emptyLabel.stringValue = message
        emptyLabel.isHidden = false
        stack.isHidden = true
        jumpBar.update(path: nil, files: [], current: nil, style: Style.current(for: view.effectiveAppearance))
    }

    /// Lays out and renders again, such as after toggling split, folds, notes or highlighting.
    func reload(keepPosition: Bool) {
        let pos = keepPosition ? topPosition : nil
        let topOffset = keepPosition ? offsetWithinTopRow : 0
        emptyLabel.isHidden = true
        stack.isHidden = false
        layout = layoutRows(files: files, overview: overview, split: split, showAll: showAll, notes: notes)
        setColumnCount(layout.right == nil ? 1 : 2)
        let style = Style.current(for: view.effectiveAppearance)
        let byID = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let sides = layout.right.map { [layout.left, $0] } ?? [layout.left]
        for (i, rows) in sides.enumerated() {
            let c = columns[i]
            c.code.style = style
            c.code.setContent(render(rows, side: sides.count == 2 ? i : -1, files: files, notes: byID, style: style), rows: rows, files: files)
            c.scroll.backgroundColor = style.theme.canvas
            c.gutter.columns = sides.count == 2 || !files.contains(where: \.isChange) ? 1 : 2
            c.gutter.updateThickness()
        }
        if let pos { scroll(to: pos, animated: false, offset: topOffset) }
        updateJumpBar()
    }

    /// The new side, or the only column.
    var primary: CodeView { columns.last!.code }

    /// Returns a line's rect in the column that shows it, for anchoring popovers.
    func rect(file: Int, line: Int) -> (NSRect, NSView)? {
        for c in columns.reversed() {
            if let r = c.code.rows.firstIndex(where: { $0.file == file && $0.kind == .line && $0.line == line }) {
                return (c.code.rect(ofRow: r), c.code)
            }
        }
        return nil
    }

    func rect(ofNote id: UUID) -> (NSRect, NSView)? {
        let code = primary
        guard let r = code.rows.firstIndex(where: { $0.kind == .note(id) }) else { return nil }
        return (code.rect(ofRow: r), code)
    }

    /// The selected word, or the word at the insertion point.
    var wordAtCaret: String? {
        let code = activeCode
        var r = code.selectedRange()
        if r.length == 0, let ident = code.identifier(at: r.location) { r = ident }
        guard r.length > 0, r.length < 200, let s = code.textStorage?.attributedSubstring(from: r).string.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty, !s.contains("\n") else { return nil }
        return s
    }

    func scrollBy(lines n: CGFloat) {
        scrollColumns(toY: primary.visibleRect.minY + n * primary.style.lineHeight, animated: false)
    }

    private func row(atY y: CGFloat, in code: CodeView) -> Int? {
        guard let lm = code.layoutManager, let tc = code.textContainer else { return nil }
        let glyph = lm.glyphIndex(for: NSPoint(x: 0, y: y - code.textContainerOrigin.y), in: tc)
        return code.row(at: lm.characterIndexForGlyph(at: glyph))
    }

    private func topRow(_ code: CodeView) -> Int? { row(atY: code.visibleRect.minY + 2, in: code) }

    /// The row at the top of the viewport, as a file and line.
    var topPosition: ReaderPosition? {
        let code = primary
        guard let r = topRow(code) else { return nil }
        let rows = code.rows
        for i in r..<min(rows.count, r + 50) where rows[i].kind == .line {
            return ReaderPosition(file: rows[i].file, line: rows[i].line)
        }
        return rows.indices.contains(r) ? ReaderPosition(file: rows[r].file, line: max(0, rows[r].line)) : nil
    }

    private var offsetWithinTopRow: CGFloat {
        let code = primary
        guard let r = topRow(code) else { return 0 }
        return code.visibleRect.minY - code.rect(ofRow: r).minY
    }

    /// The file under the top of the viewport (overview) or the file shown.
    var currentFile: Int? {
        guard !files.isEmpty else { return nil }
        if !overview { return 0 }
        let code = primary
        guard let r = topRow(code) else { return 0 }
        return code.rows[min(r + 1, code.rows.count - 1)].file
    }

    func row(for p: ReaderPosition, in code: CodeView) -> Int? {
        let rows = code.rows
        if let exact = rows.firstIndex(where: { $0.file == p.file && $0.kind == .line && $0.line == p.line }) { return exact }
        if let fold = rows.firstIndex(where: { r in
            if case .fold(let range) = r.kind { return r.file == p.file && range.contains(p.line) }
            return false
        }), case .fold(let range) = rows[fold].kind {
            files[p.file].unfolded.insert(range.lowerBound)
            reload(keepPosition: false)
            return code.rows.firstIndex { $0.file == p.file && $0.kind == .line && $0.line == p.line }
        }
        return rows.firstIndex { $0.file == p.file && $0.kind == .line && $0.line >= p.line } ?? rows.firstIndex { $0.file == p.file }
    }

    func scroll(to p: ReaderPosition, animated: Bool, offset: CGFloat? = nil, select: Bool = false) {
        guard let r = row(for: p, in: primary) else { return }
        let code = primary
        let rect = code.rect(ofRow: r)
        let viewport = code.visibleRect.height
        let y = offset.map { rect.minY + $0 } ?? max(0, rect.minY - viewport * 0.25)
        scrollColumns(toY: y, animated: animated)
        if select {
            let range = code.charRange(ofRow: r)
            code.setSelectedRange(NSRange(location: range.location, length: 0))
            code.showFindIndicator(for: range)
        }
        updateJumpBar()
    }

    func scrollToTop() { scrollColumns(toY: 0, animated: false) }

    private func scrollColumns(toY y: CGFloat, animated: Bool) {
        for c in columns {
            let clip = c.scroll.contentView
            let target = clip.constrainBoundsRect(NSRect(origin: NSPoint(x: clip.bounds.minX, y: y), size: clip.bounds.size)).origin
            if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    clip.animator().setBoundsOrigin(target)
                }
            } else {
                clip.setBoundsOrigin(target)
            }
            c.scroll.reflectScrolledClipView(clip)
        }
    }

    @objc private func scrolled(_ n: Notification) {
        guard !syncing, let clip = n.object as? NSClipView else { return }
        if columns.count == 2 {
            syncing = true
            for c in columns where c.scroll.contentView !== clip {
                c.scroll.contentView.setBoundsOrigin(clip.bounds.origin)
                c.scroll.reflectScrolledClipView(c.scroll.contentView)
            }
            syncing = false
        }
        let before = jumpBar.currentFile
        updateJumpBar()
        if jumpBar.currentFile != before { delegate?.readerCurrentFileChanged() }
    }

    /// The rows where each run of changed lines starts.
    private var changeStops: [Int] {
        let rows = primary.rows
        var stops: [Int] = []
        var prev = false
        for (i, r) in rows.enumerated() {
            var changed = false
            if r.kind == .line { changed = files[r.file].lines[r.line].kind != .context }
            if case .filler = r.kind { changed = true }
            if changed && !prev { stops.append(i) }
            prev = changed
        }
        return stops
    }

    /// Moves to the next or previous change.
    ///
    /// - Returns: False if there is no change in that direction.
    @discardableResult
    func nextChange(_ dir: Int) -> Bool {
        let code = primary
        guard let marker = row(atY: code.visibleRect.minY + code.visibleRect.height * 0.25 + 1, in: code) else { return false }
        let stops = changeStops
        let target = dir > 0 ? stops.first { $0 > marker } : stops.last { $0 < marker }
        guard let r = target else { return false }
        scrollColumns(toY: code.rect(ofRow: r).minY - code.visibleRect.height * 0.25, animated: true)
        return true
    }

    var hasChanges: Bool { !changeStops.isEmpty }

    func scrollToFirstChange() {
        guard let first = changeStops.first else { return }
        let code = primary
        scrollColumns(toY: code.rect(ofRow: first).minY - code.visibleRect.height * 0.25, animated: false)
        updateJumpBar()
    }

    func scrollToLastChange() {
        guard let last = changeStops.last else { return }
        let code = primary
        scrollColumns(toY: code.rect(ofRow: last).minY - code.visibleRect.height * 0.25, animated: false)
        updateJumpBar()
    }

    /// Moves to the next or previous file's header in the overview.
    @discardableResult
    func nextFile(_ dir: Int) -> Bool {
        let code = primary
        guard let top = topRow(code) else { return false }
        let current = code.rows[top].file
        let headers = code.rows.indices.filter { code.rows[$0].kind == .header }
        let target = dir > 0 ? headers.first { code.rows[$0].file > current } : headers.last { code.rows[$0].file < current }
        guard let r = target else { return false }
        scrollColumns(toY: code.rect(ofRow: r).minY + code.style.lineHeight, animated: true)
        return true
    }

    func scrollToFile(_ fi: Int) {
        let code = primary
        guard let r = code.rows.firstIndex(where: { $0.file == fi && $0.kind == .header }) else { return }
        scrollColumns(toY: code.rect(ofRow: r).minY + (r == 0 ? 0 : code.style.lineHeight), animated: true)
    }

    /// The selected source lines of the active column, as a file and line indices.
    var selection: (file: Int, lines: [Int])? {
        let code = activeCode
        let rows = code.selectedRows
        guard let first = rows.first else { return nil }
        let file = code.rows[first].file
        return (file, rows.filter { code.rows[$0].file == file }.map { code.rows[$0].line })
    }

    var selectedText: String? {
        let code = activeCode
        let r = code.selectedRange()
        guard r.length > 0 else { return nil }
        return code.textStorage?.attributedSubstring(from: r).string
    }

    func focus() {
        view.window?.makeFirstResponder(primary)
    }

    var isFocused: Bool { columns.contains { $0.code.window?.firstResponder === $0.code } }

    func performFind(_ sender: Any?) {
        if view.window?.firstResponder is CodeView == false { focus() }
        activeCode.performTextFinderAction(sender)
    }

    func updateJumpBar() {
        let cur = currentFile
        let style = Style.current(for: view.effectiveAppearance)
        if overview {
            jumpBar.update(path: nil, files: files, current: cur, style: style)
        } else if let f = files.first {
            jumpBar.update(path: f.path, files: files, current: 0, style: style)
            let top = f.lines.isEmpty ? nil : topPosition.map { f.lines[min($0.line, f.lines.count - 1)] }
            jumpBar.updateSymbol(line: top.map { $0.newNo > 0 ? $0.newNo - 1 : max(0, $0.oldNo - 1) })
        }
    }

    func codeView(_ v: CodeView, perform action: ReaderAction) {
        switch action {
        case .unfold(let file, let at):
            files[file].unfolded.insert(at)
            reload(keepPosition: true)
            delegate?.readerUnfolded()
        case .openFile(let file, let line):
            delegate?.readerOpenFile(file, line: line)
        case .editNote(let id):
            delegate?.readerEditNote(id)
        }
    }

    func codeView(_ v: CodeView, jumpToDefinitionOf word: String, row: Int) {
        let r = v.rows[row]
        delegate?.readerJumpToDefinition(word, file: r.file, line: r.line)
    }

    func codeViewMenu(_ v: CodeView, row: Int?) -> NSMenu? {
        let r = row.map { v.rows[$0] }
        return delegate?.readerMenu(file: r?.file, line: r?.kind == .line ? r?.line : nil)
    }
}

/// The bar above the code, showing where you are (path, symbol) and the size of the change.
@MainActor
final class JumpBar: NSView {
    let path = NSPathControl()
    let symbols = NSPopUpButton(frame: .zero, pullsDown: true)
    let stats = NSTextField(labelWithString: "")
    private(set) var currentFile: Int?
    private var definitions: [Symbol] = []
    private var shownKey = ""
    var onSelectSymbol: ((Symbol) -> Void)?
    var onSelectPath: ((String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        path.pathStyle = .standard
        path.isEditable = false
        path.focusRingType = .none
        path.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        path.controlSize = .small
        path.target = self
        path.action = #selector(pathClicked)
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        symbols.isBordered = false
        symbols.controlSize = .small
        symbols.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        (symbols.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        symbols.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        symbols.isHidden = true
        stats.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        stats.setContentCompressionResistancePriority(.required, for: .horizontal)
        stats.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [path, symbols, NSView(), stats])
        row.orientation = .horizontal
        row.spacing = 2
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

    override var isFlipped: Bool { false }

    func update(path p: String?, files: [FileState], current: Int?, style: Style) {
        let key = "\(p ?? "\u{0}")|\(current ?? -1)|\(files.map { "\(ObjectIdentifier($0).hashValue):\($0.lines.count)" })|\(style.theme.name)|\(style.theme.color("success"))|\(style.theme.color("danger"))"
        guard key != shownKey else { return }
        shownKey = key
        currentFile = current
        var items: [NSPathControlItem] = []
        func item(_ title: String, image: NSImage?) -> NSPathControlItem {
            let i = NSPathControlItem()
            i.title = title
            i.image = image
            return i
        }
        let shown = p ?? current.map { files[$0].path }
        if p == nil {
            items.append(item("All Changes", image: NSImage(systemSymbolName: "square.stack", accessibilityDescription: nil)))
        }
        if let shown {
            let comps = shown.split(separator: "/").map(String.init)
            for (i, c) in comps.enumerated() {
                let isFile = i == comps.count - 1
                items.append(item(c, image: isFile ? nil : NSImage(systemSymbolName: "folder", accessibilityDescription: nil)))
            }
        }
        path.pathItems = items
        path.toolTip = shown
        let addDel: (Int, Int)
        if p == nil {
            addDel = files.reduce((0, 0)) { ($0.0 + $1.diff.additions, $0.1 + $1.diff.deletions) }
        } else {
            addDel = files.first.map { ($0.diff.additions, $0.diff.deletions) } ?? (0, 0)
        }
        let showStats = files.contains(where: \.isChange)
        let s = NSMutableAttributedString(string: "+\(addDel.0)", attributes: [.foregroundColor: style.theme.color("success")])
        s.append(NSAttributedString(string: "  −\(addDel.1)", attributes: [.foregroundColor: style.theme.color("danger")]))
        stats.attributedStringValue = s
        stats.isHidden = !showStats
        if p != nil, let f = files.first, let lang = f.language, lang.hasTags {
            let text = f.sideText(old: false).joined(separator: "\n")
            definitions = lang.symbols(text).filter(\.isDefinition)
            symbols.isHidden = definitions.isEmpty
            rebuildSymbolMenu()
        } else {
            definitions = []
            symbols.isHidden = true
        }
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

    private func symbolImage(_ kind: String) -> String {
        switch kind {
        case "class", "struct", "type", "interface", "enum", "trait", "protocol": "cube"
        case "module", "namespace", "impl": "shippingbox"
        case "method", "function": "function"
        case "constant", "variable", "field", "property": "character.textbox"
        default: "number"
        }
    }

    /// Returns the innermost definition around a zero-based, new-side line.
    func enclosing(line: Int) -> Symbol? {
        definitions.last { $0.lines.contains(line) }
    }

    /// Shows the definition enclosing a zero-based, new-side line.
    func updateSymbol(line: Int?) {
        guard !symbols.isHidden, let line else { return }
        let enclosing = enclosing(line: line) ?? definitions.last { $0.lines.lowerBound <= line }
        symbols.menu?.item(at: 0)?.title = enclosing?.name ?? "No Selection"
        symbols.synchronizeTitleAndSelectedItem()
        symbols.setTitle(enclosing?.name ?? "No Selection")
    }

    @objc private func symbolChosen(_ sender: NSMenuItem) {
        guard sender.tag < definitions.count else { return }
        onSelectSymbol?(definitions[sender.tag])
    }

    @objc private func pathClicked() {
        guard let clicked = path.clickedPathItem, let idx = path.pathItems.firstIndex(of: clicked) else { return }
        let titles = path.pathItems.map(\.title)
        let offset = titles.first == "All Changes" ? 1 : 0
        guard idx >= offset else { return }
        onSelectPath?(titles[offset...idx].joined(separator: "/"))
    }

    func showSymbolMenu() {
        guard !symbols.isHidden else { NSSound.beep(); return }
        symbols.performClick(nil)
    }
}
