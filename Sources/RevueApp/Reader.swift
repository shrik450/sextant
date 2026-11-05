import AppKit
import RevueCore

@MainActor
protocol ReaderDelegate: AnyObject {
    /// Tells the delegate the reader's code took the keyboard.
    func readerFocused(_ r: Reader)
    func readerOpenFile(_ r: Reader, file: Int, line: Int?)
    func readerUnfolded(_ r: Reader)
    func readerJumpToDefinition(_ r: Reader, word: String, file: Int, line: Int)
    func readerEditNote(_ r: Reader, id: UUID)
    func readerMenu(_ r: Reader, file: Int?, line: Int?) -> NSMenu?
    func readerCurrentFileChanged(_ r: Reader)
    func readerBlameClicked(_ r: Reader, commit: Blame.Commit, line: Int)
    func readerCaretMoved(_ r: Reader)
    func readerAddNote(_ r: Reader)
    func readerPeek(_ r: Reader)
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
    let header = PaneHeader()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var layout = Layout(left: [], right: nil)
    private var syncing = false

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        header.translatesAutoresizingMaskIntoConstraints = false
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
        v.addSubview(header)
        v.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: v.topAnchor),
            header.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: header.bottomAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: v.safeAreaLayoutGuide.topAnchor),
            {
                let snug = stack.topAnchor.constraint(equalTo: header.bottomAnchor)
                snug.priority = .defaultLow
                return snug
            }(),
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
        guard !files.isEmpty else {
            paintCanvas(Style.current(for: view.effectiveAppearance))
            return
        }
        reload(keepPosition: true)
    }

    /// Fills the pane behind its header and code with the theme's canvas, so they read as one.
    private func paintCanvas(_ style: Style) {
        view.layer?.backgroundColor = style.theme.canvas.cgColor
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
            gutter.onBlameClick = { [weak self] c, line in
                guard let self else { return }
                self.delegate?.readerBlameClicked(self, commit: c, line: line)
            }
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
        columns.first { $0.code.window?.firstResponder === $0.code }?.code
            ?? activeColumn.flatMap { c in columns.contains { $0.code === c } ? c : nil }
            ?? columns.last!.code
    }

    func show(files: [FileState], overview: Bool, at position: ReaderPosition? = nil) {
        self.files = files
        self.overview = overview
        usesWord = nil
        cancelJump()
        reload(keepPosition: false)
        if let position { scroll(to: position, animated: false) } else { scrollToTop() }
        analyzeShownFiles()
    }

    private var analysis: Task<Void, Never>?

    /// Analyzes the files shown, nearest the view first, coloring each as it arrives.
    ///
    /// The overview only needs colors; one file needs its definitions and outline too.
    private func analyzeShownFiles() {
        analysis?.cancel()
        let shown = files, symbols = !overview
        analysis = Task {
            var tried = Set<ObjectIdentifier>()
            while !Task.isCancelled, let f = nextToAnalyze(shown, symbols: symbols, skipping: tried) {
                tried.insert(ObjectIdentifier(f))
                await f.analyze(symbols: symbols)
                guard !Task.isCancelled, let fi = files.firstIndex(where: { $0 === f }) else { return }
                analyzed(file: fi)
            }
        }
    }

    private func nextToAnalyze(_ shown: [FileState], symbols: Bool, skipping tried: Set<ObjectIdentifier>) -> FileState? {
        let here = currentFile ?? 0
        return shown.indices
            .filter { i in
                let f = shown[i]
                return f.hasLanguage && !tried.contains(ObjectIdentifier(f)) && (f.tokens == nil || symbols && f.outline == nil)
            }
            .min { abs($0 - here) * 2 + ($0 < here ? 1 : 0) < abs($1 - here) * 2 + ($1 < here ? 1 : 0) }
            .map { shown[$0] }
    }

    /// Shows a file's colors once its analysis arrives, and lands the caret again if it landed
    /// by itself, since the names it lands on depend on the analysis.
    private func analyzed(file fi: Int) {
        let reland = landedSelection != nil && landedSelection == keptSelection
        for c in columns { c.code.recolor(file: fi) }
        if reland, let r = caretRow { placeCaret(atRow: r) }
        updateHeader()
    }

    /// Whether everything in view is drawn with its colors.
    var isSettled: Bool { !columns.contains { $0.code.awaitsColors } }

    func showEmpty(_ message: String) {
        files = []
        layout = Layout(left: [], right: nil)
        for c in columns { c.code.setContent(RenderedText(string: NSAttributedString(), rowStarts: []), rows: [], files: []) }
        emptyLabel.stringValue = message
        emptyLabel.isHidden = false
        stack.isHidden = true
        let style = Style.current(for: view.effectiveAppearance)
        paintCanvas(style)
        header.update(path: nil, files: [], current: nil, style: style)
    }

    /// Lays out and renders again, such as after toggling split, folds, notes or highlighting.
    func reload(keepPosition: Bool) {
        let pos = keepPosition ? topPosition : nil
        let kept = keepPosition ? keptSelection : nil
        let topOffset = keepPosition ? offsetFromTopPosition : 0
        emptyLabel.isHidden = true
        stack.isHidden = false
        layout = layoutRows(files: files, overview: overview, split: split, showAll: showAll, notes: notes)
        setColumnCount(layout.right == nil ? 1 : 2)
        let style = Style.current(for: view.effectiveAppearance)
        paintCanvas(style)
        let byID = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let sides = layout.right.map { [layout.left, $0] } ?? [layout.left]
        let files = self.files
        let isRead = self.isRead
        for (i, rows) in sides.enumerated() {
            let c = columns[i]
            c.code.style = style
            c.code.isReadLine = { fi, li in files[fi].run(at: li).map { isRead(files[fi], $0) } ?? false }
            c.code.setContent(render(rows, side: sides.count == 2 ? i : -1, files: files, notes: byID, style: style), rows: rows, files: files)
            c.scroll.backgroundColor = style.theme.canvas
            c.gutter.columns = sides.count == 2 || !files.contains(where: \.isChange) ? 1 : 2
            c.gutter.updateThickness()
        }
        if let pos { scroll(to: pos, animated: false, offset: topOffset) }
        if let kept {
            restore(kept)
            if kept == landedSelection, let r = caretRow { placeCaret(atRow: r) }
        } else {
            columns.forEach { $0.code.setSelectedRange(NSRange(location: 0, length: 0)) }
        }
        markUses()
        updateHeader()
    }

    /// Says whether a run of changes has been read.
    var isRead: (FileState, FileState.KeyedRun) -> Bool = { _, _ in false }

    /// Redraws the change bars after runs were read or unread.
    /// Redraws changes in their read or unread colors.
    func refreshReadState() {
        for c in columns {
            for i in files.indices { c.code.recolor(file: i) }
            c.code.needsDisplay = true
            c.gutter.needsDisplay = true
        }
    }

    /// The run of changes the caret is in, with its file.
    var caretRun: (file: FileState, run: FileState.KeyedRun)? {
        guard let p = caret, files.indices.contains(p.file), let r = files[p.file].run(at: p.line) else { return nil }
        return (files[p.file], r)
    }

    /// The caret's column in its line, as a UTF-16 offset.
    var caretColumn: Int? {
        let code = activeCode
        guard let r = caretRow, code.rows.indices.contains(r) else { return nil }
        return code.selectedRange().location - code.rowStarts[r]
    }

    /// Where the caret's word is on screen, for anchoring a popover to it: the word the caret is
    /// on, or the selection, which is the word `wordAtCaret` names when there is one.
    var caretAnchor: (NSRect, NSView)? {
        let code = activeCode
        guard let rect = code.caretRect ?? code.selectionRect else { return nil }
        return (rect, code)
    }

    /// Opens the folded unchanged lines nearest the caret.
    ///
    /// - Returns: False if there are none.
    @discardableResult
    func unfoldNearest() -> Bool {
        let code = activeCode
        guard let r = caretRow ?? topRow(code) else { return false }
        let folds = code.rows.indices.filter { if case .fold = code.rows[$0].kind { true } else { false } }
        guard let nearest = folds.min(by: { abs($0 - r) < abs($1 - r) }), case .fold(let range) = code.rows[nearest].kind else { return false }
        files[code.rows[nearest].file].unfolded.insert(range.lowerBound)
        reload(keepPosition: true)
        return true
    }

    /// The name whose uses are highlighted.
    private(set) var usesWord: String?

    /// Highlights every use of the name at the caret in what the reader shows.
    ///
    /// - Returns: False if the caret isn't on a name.
    @discardableResult
    func highlightUses() -> Bool {
        guard let w = wordAtCaret, w.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }) else { return false }
        usesWord = w
        markUses()
        return true
    }

    func clearUses() {
        usesWord = nil
        markUses()
    }

    private func markUses() {
        for c in columns {
            guard let w = usesWord, let s = c.code.textStorage?.string as NSString? else { c.code.uses = []; continue }
            var found: [NSRange] = []
            for (r, row) in c.code.rows.enumerated() where row.kind == .line {
                let range = c.code.charRange(ofRow: r)
                found += wholeWordMatches(of: w, in: s.substring(with: range)).map { NSRange(location: $0.location + range.location, length: $0.length) }
            }
            c.code.uses = found
        }
    }

    /// Moves the caret to the next or previous highlighted use.
    ///
    /// - Returns: False if there's none in that direction.
    @discardableResult
    func stepUse(_ dir: Int) -> Bool {
        let code = activeCode
        let at = code.selectedRange().location
        let start = code.identifier(at: at).map { NSLocationInRange(at, NSRange(location: $0.location, length: $0.length + 1)) ? $0.location : at } ?? at
        guard let next = dir > 0 ? code.uses.first(where: { $0.location > start }) : code.uses.last(where: { $0.location < start }) else { return false }
        code.setSelectedRange(NSRange(location: next.location, length: 0))
        code.scrollRangeToVisible(next)
        return true
    }

    private enum Jump {
        /// Waiting for the two characters to look for.
        case typing(String)
        /// Waiting for the label of one of several places.
        case picking(targets: [(code: CodeView, index: Int)], labels: [String], typed: String)
    }

    private var jump: Jump? { didSet { showJumpPrompt() } }
    private lazy var jumpPrompt: JumpPrompt = {
        let p = JumpPrompt()
        p.translatesAutoresizingMaskIntoConstraints = false
        p.isHidden = true
        view.addSubview(p)
        NSLayoutConstraint.activate([
            p.centerXAnchor.constraint(equalTo: stack.centerXAnchor),
            p.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: -20),
        ])
        return p
    }()

    /// Starts a jump: two typed characters, then a label if they appear in more than one place
    /// on screen.
    func startJump() {
        focus()
        jump = .typing("")
    }

    private func cancelJump() {
        guard jump != nil else { return }
        jump = nil
        for c in columns { c.code.jumpLabels = [] }
    }

    private func showJumpPrompt() {
        switch jump {
        case nil: jumpPrompt.isHidden = true
        case .typing(let q)?:
            jumpPrompt.isHidden = false
            if q.count < 2 {
                jumpPrompt.show(q.isEmpty ? "Type two characters to jump to" : "Jump to", typed: q)
            } else {
                jumpPrompt.show("Nothing on screen matches", typed: q)
            }
        case .picking(_, _, let typed)?:
            jumpPrompt.isHidden = false
            jumpPrompt.show("Type a label", typed: typed)
        }
    }

    private func handleJump(_ event: NSEvent, _ state: Jump) {
        if event.keyCode == 53 { cancelJump(); return }
        let backspace = event.keyCode == 51
        guard let c = event.characters, backspace || (c.count == 1 && !(c.first?.isNewline ?? true)) else { cancelJump(); return }
        switch state {
        case .typing(let q):
            let query = backspace ? String(q.dropLast()) : (q.count < 2 ? q : "") + c
            guard query.count == 2 else { jump = .typing(query); return }
            let targets = jumpTargets(query)
            switch targets.count {
            case 0: NSSound.beep(); jump = .typing(query)
            case 1: land(targets[0])
            default:
                let labels = jumpLabels(targets.count)
                for col in columns { col.code.jumpLabels = zip(targets, labels).filter { $0.0.code === col.code }.map { ($0.0.index, $0.1) } }
                jump = .picking(targets: targets, labels: labels, typed: "")
            }
        case .picking(let targets, let labels, let typed):
            if backspace { for col in columns { col.code.jumpLabels = [] }; jump = .typing(""); return }
            let t = typed + c
            if let i = labels.firstIndex(of: t) { land(targets[i]); return }
            guard labels.contains(where: { $0.hasPrefix(t) }) else { NSSound.beep(); cancelJump(); return }
            jump = .picking(targets: targets, labels: labels, typed: t)
        }
    }

    private func jumpTargets(_ query: String) -> [(code: CodeView, index: Int)] {
        var out: [(code: CodeView, index: Int)] = []
        for c in columns {
            var rows: [Int] = []
            c.code.visibleRows(in: c.code.visibleRect) { r, _ in if c.code.rows[r].kind == .line { rows.append(r) } }
            let s = (c.code.textStorage?.string ?? "") as NSString
            let lines = rows.map { s.substring(with: c.code.charRange(ofRow: $0)) }
            out += RevueCore.jumpTargets(for: query, in: lines).map { (c.code, c.code.rowStarts[rows[$0.line]] + $0.column) }
        }
        return out
    }

    private func land(_ target: (code: CodeView, index: Int)) {
        cancelJump()
        view.window?.makeFirstResponder(target.code)
        target.code.setSelectedRange(NSRange(location: target.index, length: 0))
        activeColumn = target.code
        markActiveColumn()
    }

    func codeView(_ v: CodeView, intercept event: NSEvent) -> Bool {
        if let jump { handleJump(event, jump); return true }
        let plain = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        if plain, event.characters == "*" {
            if !highlightUses() { NSSound.beep() }
            return true
        }
        if plain, event.keyCode == 36 || event.keyCode == 76, !event.modifierFlags.contains(.shift) {
            delegate?.readerPeek(self)
            return true
        }
        if plain, event.keyCode == 53, usesWord != nil, v.selectedRange().length == 0 {
            clearUses()
            return true
        }
        return false
    }

    func codeViewAddNote(_ v: CodeView) { delegate?.readerAddNote(self) }

    func codeViewFocused(_ v: CodeView) { delegate?.readerFocused(self) }

    /// Where the caret last landed by itself, so it can land again once highlighting shows which
    /// names the line has.
    private var landedSelection: KeptSelection?

    /// A selection by line, which survives the text being rendered again.
    private struct KeptSelection: Equatable {
        var side: Int
        var position: ReaderPosition
        var column: Int
        var length: Int
    }

    private var keptSelection: KeptSelection? {
        let code = activeCode
        guard let r = caretRow, code.rows.indices.contains(r), code.rows[r].kind == .line else { return nil }
        let sel = code.selectedRange()
        return KeptSelection(side: columns.firstIndex { $0.code === code } ?? 0, position: ReaderPosition(file: code.rows[r].file, line: code.rows[r].line),
                             column: sel.location - code.rowStarts[r], length: sel.length)
    }

    private func restore(_ k: KeptSelection) {
        let code = columns.indices.contains(k.side) ? columns[k.side].code : primary
        guard let r = code.rows.firstIndex(where: { $0.file == k.position.file && $0.kind == .line && $0.line == k.position.line }) else { return }
        let range = code.charRange(ofRow: r)
        let start = range.location + min(k.column, range.length)
        code.setSelectedRange(NSRange(location: start, length: min(k.length, (code.textStorage?.length ?? start) - start)))
        activeColumn = code
        markActiveColumn()
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

    /// The first line at or below the top of the viewport, with its row.
    ///
    /// Headers, gaps and folds have no line to return to, so the line below them stands in.
    private var topAnchor: (row: Int, position: ReaderPosition)? {
        let code = primary
        guard let r = topRow(code) else { return nil }
        let rows = code.rows
        if let i = (r..<min(rows.count, r + 50)).first(where: { rows[$0].kind == .line }) {
            return (i, ReaderPosition(file: rows[i].file, line: rows[i].line))
        }
        return rows.indices.contains(r) ? (r, ReaderPosition(file: rows[r].file, line: max(0, rows[r].line))) : nil
    }

    /// The row at the top of the viewport, as a file and line.
    var topPosition: ReaderPosition? { topAnchor?.position }

    /// How far the top of the viewport sits below the top position's row; negative when above it.
    private var offsetFromTopPosition: CGFloat {
        guard let a = topAnchor else { return 0 }
        return primary.visibleRect.minY - primary.rect(ofRow: a.row).minY
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

    /// Scrolls to a line, putting it a quarter of the way down unless `offset` places it.
    ///
    /// - Parameter select: Whether to put the caret on the line too.
    func scroll(to p: ReaderPosition, animated: Bool, offset: CGFloat? = nil, select: Bool = false) {
        guard let r = row(for: p, in: primary) else { return }
        let code = primary
        let rect = code.rect(ofRow: r)
        scrollColumns(toY: offset.map { rect.minY + $0 } ?? max(0, rect.minY - code.visibleRect.height * 0.25), animated: animated)
        if select { placeCaret(atRow: r) }
        updateHeader()
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

    /// Scrolls a row a quarter of the way down the view and puts the caret on it.
    private func land(onRow r: Int, animated: Bool) {
        let code = primary
        scrollColumns(toY: code.rect(ofRow: r).minY - code.visibleRect.height * 0.25, animated: animated)
        placeCaret(atRow: r)
        updateHeader()
    }

    /// Puts the caret on a row, at its first character that isn't a space.
    ///
    /// In side by side, the caret goes to the column where the row is a line, the new side first.
    func placeCaret(atRow r: Int) {
        guard let code = columns.reversed().map(\.code).first(where: { $0.rows.indices.contains(r) && $0.rows[r].kind == .line })
            ?? (primary.rows.indices.contains(r) ? primary : nil) else { return }
        place(in: code, at: code.landingIndex(ofRow: r))
        landedSelection = keptSelection
    }

    private func place(in code: CodeView, at i: Int) {
        if isFocused, view.window?.firstResponder !== code { view.window?.makeFirstResponder(code) }
        code.setSelectedRange(NSRange(location: i, length: 0))
        activeColumn = code
        markActiveColumn()
    }

    private func markActiveColumn() {
        for c in columns { c.code.showsCurrentLine = c.code === activeCode }
    }

    /// The column the caret was last put in, which keeps it when focus leaves the reader.
    private weak var activeColumn: CodeView?

    /// The row the caret is on.
    var caretRow: Int? {
        let code = activeCode
        return code.row(at: code.selectedRange().location)
    }

    /// The line the caret is on.
    var caret: ReaderPosition? {
        let code = activeCode
        guard let r = caretRow, code.rows.indices.contains(r), code.rows[r].kind == .line else { return nil }
        return ReaderPosition(file: code.rows[r].file, line: code.rows[r].line)
    }

    /// Whether the caret is in view, so moves start from it rather than from the top of the view.
    ///
    /// A row that isn't laid out isn't on screen, so this never lays out more text.
    private var caretInView: Bool {
        guard let r = caretRow, let rect = primary.laidOutRect(ofRow: r) else { return false }
        return primary.visibleRect.intersects(rect)
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
        for c in columns { c.code.colorVisibleRows() }
        let before = header.currentFile
        updateHeader()
        if header.currentFile != before { delegate?.readerCurrentFileChanged(self) }
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

    /// Moves to the next or previous change from the caret, or from the top of the view when the
    /// caret is out of sight.
    ///
    /// - Returns: False if there is no change in that direction.
    @discardableResult
    func nextChange(_ dir: Int) -> Bool {
        let code = primary
        let from = caretInView ? caretRow : row(atY: code.visibleRect.minY + code.visibleRect.height * 0.25 + 1, in: code)
        guard let from else { return false }
        let stops = changeStops
        guard let r = dir > 0 ? stops.first(where: { $0 > from }) : stops.last(where: { $0 < from }) else { return false }
        land(onRow: r, animated: true)
        return true
    }

    var hasChanges: Bool { !changeStops.isEmpty }

    func scrollToFirstChange() {
        guard let first = changeStops.first else { return }
        land(onRow: first, animated: false)
    }

    func scrollToLastChange() {
        guard let last = changeStops.last else { return }
        land(onRow: last, animated: false)
    }

    /// Moves to the next or previous file in the overview.
    @discardableResult
    func nextFile(_ dir: Int) -> Bool {
        let code = primary
        guard let from = caretInView ? caretRow : topRow(code) else { return false }
        let current = code.rows[from].file
        guard let next = dir > 0 ? files.indices.first(where: { $0 > current }) : files.indices.last(where: { $0 < current }) else { return false }
        scrollToFile(next)
        return true
    }

    /// Scrolls the overview to a file, with the caret on its first line.
    func scrollToFile(_ fi: Int) {
        let code = primary
        guard let r = code.rows.firstIndex(where: { $0.file == fi && $0.kind == .header }) else { return }
        scrollColumns(toY: code.rect(ofRow: r).minY + (r == 0 ? 0 : code.style.lineHeight), animated: true)
        if let first = code.rows[r...].firstIndex(where: { $0.file == fi && $0.kind == .line }) { placeCaret(atRow: first) }
        updateHeader()
    }

    /// Moves the caret to the next or previous definition in the file.
    ///
    /// - Parameters:
    ///   - dir: 1 for the next definition, -1 for the previous one.
    ///   - changedOnly: Whether to stop only at definitions the change touched directly, as the
    ///     inspector's outline lists them with Changed Only on.
    /// - Returns: False if there is none in that direction.
    @discardableResult
    func stepDefinition(_ dir: Int, changedOnly: Bool) -> Bool {
        guard !overview, let f = files.first, !f.lines.isEmpty else { return false }
        if changedOnly { return stepChangedDefinition(dir, in: f) }
        let here = caret.map { f.lines[$0.line] }.map { $0.kind == .deleted ? max(0, $0.newNo) : $0.newNo - 1 } ?? currentNewLine ?? 0
        let starts = Set(header.definitions.map(\.nameLine)).sorted()
        guard let next = dir > 0 ? starts.first(where: { $0 > here }) : starts.last(where: { $0 < here }),
              let i = f.index(ofLine: next + 1), let r = row(for: ReaderPosition(file: 0, line: i), in: primary) else { return false }
        land(onRow: r, animated: true)
        return true
    }

    private func stepChangedDefinition(_ dir: Int, in f: FileState) -> Bool {
        let here = caret?.line ?? topPosition?.line ?? 0
        let starts = changedDefinitions(in: f.outline ?? [], lines: f.lines).compactMap { d -> Int? in
            let old = d.change == .deleted
            return f.lines.firstIndex { old ? $0.kind == .deleted && $0.oldNo == d.line + 1 : $0.kind != .deleted && $0.newNo == d.line + 1 }
        }
        let sorted = Set(starts).sorted()
        guard let next = dir > 0 ? sorted.first(where: { $0 > here }) : sorted.last(where: { $0 < here }),
              let r = row(for: ReaderPosition(file: 0, line: next), in: primary) else { return false }
        land(onRow: r, animated: true)
        return true
    }

    /// Puts the caret on a line without scrolling, at a column or where it lands on that line.
    func placeCaret(at p: ReaderPosition, column: Int? = nil) {
        guard let r = row(for: p, in: primary) else { return }
        if let column, let code = columns.reversed().map(\.code).first(where: { $0.rows.indices.contains(r) && $0.rows[r].kind == .line }) {
            let range = code.charRange(ofRow: r)
            place(in: code, at: range.location + min(column, range.length))
        } else {
            placeCaret(atRow: r)
        }
        updateHeader()
    }

    /// Moves the caret to a line of the shown file, by index into its lines.
    func land(onLine i: Int, file: Int = 0) {
        guard let r = row(for: ReaderPosition(file: file, line: i), in: primary) else { return }
        land(onRow: r, animated: true)
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
        view.window?.makeFirstResponder(activeColumn.flatMap { c in columns.contains { $0.code === c } ? c : nil } ?? primary)
    }

    var isFocused: Bool { columns.contains { $0.code.window?.firstResponder === $0.code } }

    func performFind(_ sender: Any?) {
        if view.window?.firstResponder is CodeView == false { focus() }
        activeCode.performTextFinderAction(sender)
    }

    /// The zero-based new-side line at the caret when it's in view, else at the top of the view.
    private var currentNewLine: Int? {
        guard !overview, let f = files.first, !f.lines.isEmpty else { return nil }
        let p = (caretInView ? caret : nil) ?? topPosition
        return p.map { f.lines[min($0.line, f.lines.count - 1)] }.map { $0.newNo > 0 ? $0.newNo - 1 : max(0, $0.oldNo - 1) }
    }

    func updateHeader() {
        let style = primary.style
        if overview {
            header.update(path: nil, files: files, current: currentFile, style: style)
        } else if let f = files.first {
            header.update(path: f.path, files: files, current: 0, style: style)
            header.updateSymbol(line: currentNewLine)
        }
    }

    func codeView(_ v: CodeView, perform action: ReaderAction) {
        switch action {
        case .unfold(let file, let at):
            files[file].unfolded.insert(at)
            reload(keepPosition: true)
            delegate?.readerUnfolded(self)
        case .openFile(let file, let line):
            delegate?.readerOpenFile(self, file: file, line: line)
        case .editNote(let id):
            delegate?.readerEditNote(self, id: id)
        }
    }

    func codeView(_ v: CodeView, jumpToDefinitionOf word: String, row: Int) {
        let r = v.rows[row]
        delegate?.readerJumpToDefinition(self, word: word, file: r.file, line: r.line)
    }

    func codeViewCaretMoved(_ v: CodeView) {
        guard v.window?.firstResponder === v || activeColumn == nil || activeColumn === v else { return }
        activeColumn = v
        markActiveColumn()
        updateHeader()
        delegate?.readerCaretMoved(self)
    }

    func codeViewMenu(_ v: CodeView, row: Int?) -> NSMenu? {
        let r = row.map { v.rows[$0] }
        return delegate?.readerMenu(self, file: r?.file, line: r?.kind == .line ? r?.line : nil)
    }
}

/// The glass capsule a jump shows over the code: what to type, then what's been typed.
@MainActor
final class JumpPrompt: NSGlassEffectView {
    private let text = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        cornerRadius = 16
        let content = NSView()
        text.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            text.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            text.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            text.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
        contentView = content
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows a prompt, followed by the keys typed so far in the code's typeface.
    func show(_ prompt: String, typed: String) {
        let s = NSMutableAttributedString(string: prompt, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.themed("fgMuted")])
        if !typed.isEmpty {
            s.append(NSAttributedString(string: "  " + typed, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor]))
        }
        text.attributedStringValue = s
    }
}
