import AppKit
import SextantCore

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

    /// The files shown, each with the text this reader shows of it and the runs it unfolded.
    private(set) var files: [ShownFile] = []
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
    /// The code view of each column, left to right.
    var codeViews: [CodeView] { columns.map(\.code) }
    private let stack = NSStackView()
    let header: PaneHeader
    private let emptyState = EmptyState(symbolSize: 40, font: .preferredFont(forTextStyle: .title3))
    private let changeCounter: ChangeCounter
    private let look: any Look
    private var layout = Layout(left: [], right: nil)
    private var syncing = false

    init(look: any Look) {
        self.look = look
        header = PaneHeader(style: look.paneHeader)
        changeCounter = ChangeCounter(look: look)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The style the code draws in, for the appearance the reader shows in and its look.
    private func currentStyle() -> Style {
        var style = Style.current(for: view.effectiveAppearance)
        style.canvasOpacity = look.canvasOpacity(of: style.theme)
        return style
    }

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        header.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.isHidden = true
        changeCounter.translatesAutoresizingMaskIntoConstraints = false
        changeCounter.isHidden = true
        v.addSubview(stack)
        v.addSubview(header)
        v.addSubview(emptyState)
        v.addSubview(changeCounter)
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
            emptyState.centerXAnchor.constraint(equalTo: stack.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: stack.centerYAnchor),
            emptyState.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, multiplier: 0.8),
            changeCounter.centerXAnchor.constraint(equalTo: stack.centerXAnchor),
            changeCounter.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: -ChangeCounter.margin),
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
            paintCanvas(currentStyle())
            return
        }
        reload(keepPosition: true)
    }

    /// Fills the pane behind its header and code with the theme's canvas, so they read as one.
    private func paintCanvas(_ style: Style) {
        view.layer?.backgroundColor = style.canvasFill.cgColor
    }

    private func setColumnCount(_ n: Int) {
        guard columns.count != n else { return }
        for c in columns { c.scroll.removeFromSuperview() }
        columns = (0..<n).map { i in
            let scroll = GutterScrollView()
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true
            scroll.autohidesScrollers = true
            scroll.findBarPosition = .aboveContent
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: ChangeCounter.clearance, right: 0)
            scroll.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: -ChangeCounter.clearance, right: 0)
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

    /// Shows one file by itself, or every change as an overview.
    ///
    /// See `text(of:)` for which of each file's texts shows.
    func show(files: [FileState], overview: Bool, at position: ReaderPosition? = nil) {
        self.overview = overview
        self.files = files.map { ShownFile(file: $0, text: text(of: $0)) }
        usesWord = nil
        boxed = nil
        cancelJump()
        reload(keepPosition: false)
        if let position { scroll(to: position, animated: false) } else { scrollToTop() }
        analyzeShownFiles()
    }

    private var analysis: Task<Void, Never>?

    /// Stops analyzing the files shown and boxing names, for a reader that's going away.
    func stopWork() {
        analysis?.cancel()
        pendingOccurrences?.cancel()
    }

    /// Analyzes the files shown, nearest the view first, coloring each as it arrives.
    ///
    /// The overview only needs colors; one file needs its definitions and outline too.
    private func analyzeShownFiles() {
        analysis?.cancel()
        let shown = files.map(\.text), symbols = !overview
        analysis = Task {
            var tried = Set<ObjectIdentifier>()
            while !Task.isCancelled, let t = nextToAnalyze(shown, symbols: symbols, skipping: tried) {
                tried.insert(ObjectIdentifier(t))
                await t.analyze(symbols: symbols)
                guard !Task.isCancelled, let fi = files.firstIndex(where: { $0.text === t }) else { return }
                analyzed(file: fi)
            }
        }
    }

    private func nextToAnalyze(_ shown: [FileText], symbols: Bool, skipping tried: Set<ObjectIdentifier>) -> FileText? {
        let here = currentFile ?? 0
        return shown.indices
            .filter { i in
                let t = shown[i]
                return t.hasLanguage && !tried.contains(ObjectIdentifier(t)) && (t.tokens == nil || symbols && t.outline == nil)
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
        if boxed == nil, caret?.file == fi { updateOccurrences() }
    }

    /// Whether everything in view is drawn with its colors.
    var isSettled: Bool { !columns.contains { $0.code.awaitsColors } }

    /// Shows a quiet message in place of any code.
    ///
    /// - Parameters:
    ///   - message: Why there's nothing to show.
    ///   - symbol: The SF Symbol shown above the message.
    func showEmpty(_ message: String, symbol: String) {
        files = []
        layout = Layout(left: [], right: nil)
        for c in columns { c.code.setContent(RenderedText(string: NSAttributedString(), rowStarts: []), rows: [], files: []) }
        emptyState.show(message, symbol: symbol)
        emptyState.isHidden = false
        stack.isHidden = true
        changeStops = []
        updateChangeCounter()
        let style = currentStyle()
        paintCanvas(style)
        header.update(path: nil, files: [], current: nil, style: style)
    }

    /// Lays out and renders again, such as after toggling split, folds, notes or highlighting.
    /// The text this reader shows of a file: the whole file once it's read, else the hunks.
    ///
    /// The overview reads no file whole itself; it shows whole, folded unless it shows unchanged
    /// lines, each change some pane read whole. What other panes read changes the overview only
    /// when it lays out again, and their folds never do.
    private func text(of f: FileState) -> FileText {
        f.wholeOrHunks
    }

    /// Shows the text `text(of:)` picks for each file, where it isn't shown already.
    ///
    /// A file whose text changes starts with nothing unfolded, since its line indices change.
    ///
    /// - Returns: The texts replaced, by file index.
    private func pickTexts() -> [Int: FileText] {
        var replaced: [Int: FileText] = [:]
        for (i, shown) in files.enumerated() {
            let t = text(of: shown.file)
            guard t !== shown.text else { continue }
            replaced[i] = shown.text
            files[i] = ShownFile(file: shown.file, text: t)
        }
        return replaced
    }

    /// Returns where a position in a replaced text is in the text that replaced it, by its line
    /// number.
    private func position(_ p: ReaderPosition, replacing replaced: [Int: FileText]) -> ReaderPosition {
        guard let old = replaced[p.file], let line = old.lineNumber(at: p.line), let moved = position(of: line, inFile: p.file) else { return p }
        return moved
    }

    func reload(keepPosition: Bool) {
        var pos = keepPosition ? topPosition : nil
        var kept = keepPosition ? keptSelection : nil
        let replaced = pickTexts()
        if !replaced.isEmpty {
            pos = pos.map { position($0, replacing: replaced) }
            if let k = kept { kept?.position = position(k.position, replacing: replaced) }
            if let l = landedSelection { landedSelection?.position = position(l.position, replacing: replaced) }
        }
        let topOffset = keepPosition ? offsetFromTopPosition : 0
        emptyState.isHidden = true
        stack.isHidden = false
        layout = layoutRows(files: files, overview: overview, split: split, showAll: showAll, notes: notes)
        setColumnCount(layout.right == nil ? 1 : 2)
        let style = currentStyle()
        paintCanvas(style)
        let byID = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let sides = layout.right.map { [layout.left, $0] } ?? [layout.left]
        let files = self.files
        let isRead = self.isRead
        for (i, rows) in sides.enumerated() {
            let c = columns[i]
            c.code.style = style
            c.code.isReadLine = { fi, li in files[fi].text.run(at: li).map { isRead(files[fi].file, $0) } ?? false }
            c.code.setContent(render(rows, side: sides.count == 2 ? i : -1, files: files, notes: byID, style: style), rows: rows, files: files)
            c.scroll.drawsBackground = false
            c.gutter.columns = sides.count == 2 || !files.contains(where: \.file.isChange) ? 1 : 2
            c.gutter.updateThickness()
        }
        changeStops = changeStarts(changedRows(layout))
        if let pos { scroll(to: pos, animated: false, offset: topOffset, unfolding: false) }
        if let kept {
            restore(kept)
            if kept == landedSelection, let r = caretRow { placeCaret(atRow: r) }
        } else {
            columns.forEach { $0.code.setSelectedRange(NSRange(location: 0, length: 0)) }
        }
        markUses()
        boxed = nil
        updateOccurrences()
        updateHeader()
        if !replaced.isEmpty { analyzeShownFiles() }
    }

    /// Says whether a run of changes has been read.
    var isRead: (FileState, FileText.KeyedRun) -> Bool = { _, _ in false }

    /// Redraws the change bars after runs were read or unread.
    /// Redraws changes in their read or unread colors.
    func refreshReadState() {
        for c in columns {
            for i in files.indices { c.code.recolor(file: i) }
            c.code.needsDisplay = true
            c.gutter.needsDisplay = true
        }
    }

    /// The run of changes the caret is in, with its file and the text it's in.
    var caretRun: (file: FileState, text: FileText, run: FileText.KeyedRun)? {
        guard let p = caret, files.indices.contains(p.file), let r = files[p.file].text.run(at: p.line) else { return nil }
        return (files[p.file].file, files[p.file].text, r)
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

    /// The file and places of the names boxed, which name what the caret's name names.
    private var boxed: (file: Int, places: [FileText.Occurrence])?
    /// The update of the boxes waiting for the caret to settle.
    private var pendingOccurrences: Task<Void, Never>?

    /// How long the caret rests on a name before the names that name the same thing are boxed,
    /// so holding a key down to move doesn't box every name on the way. A tenth of a second
    /// still feels immediate, and outlasts the default key repeat.
    private static let occurrenceDelay = Duration.milliseconds(100)

    /// The name the caret is on, or the selection when it's exactly one name, as its file, line
    /// and the caret's column in it.
    private var nameAtCaret: (file: Int, line: Int, column: Int)? {
        let code = activeCode
        let sel = code.selectedRange()
        guard let r = code.row(at: sel.location), code.rows.indices.contains(r), code.rows[r].kind == .line,
              let word = code.identifier(at: sel.location), sel.length == 0 || word == sel else { return nil }
        return (code.rows[r].file, code.rows[r].line, sel.location - code.rowStarts[r])
    }

    /// Unboxes the names as soon as the caret leaves them, and boxes the ones that name what the
    /// caret's new name names once it rests there.
    ///
    /// Moving onto another boxed name keeps the boxes as they are, since they name the same
    /// thing.
    private func caretMovedAmongNames() {
        pendingOccurrences?.cancel()
        pendingOccurrences = nil
        let at = nameAtCaret
        if let at, let b = boxed, b.file == at.file, Self.contains(b.places, line: at.line, column: at.column) { return }
        if boxed != nil { box(nil) }
        guard at != nil else { return }
        pendingOccurrences = Task { [weak self] in
            try? await Task.sleep(for: Self.occurrenceDelay)
            guard !Task.isCancelled else { return }
            self?.updateOccurrences()
        }
    }

    /// Whether the caret is on or just after one of some places in a line.
    private static func contains(_ places: [FileText.Occurrence], line: Int, column: Int) -> Bool {
        var lo = 0, hi = places.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if places[mid].line < line { lo = mid + 1 } else { hi = mid }
        }
        return places[lo...].prefix { $0.line == line }.contains { NSLocationInRange(column, $0.range) || NSMaxRange($0.range) == column }
    }

    /// Boxes the names that name what the caret's name names, indexing the file's names first if
    /// they aren't yet.
    private func updateOccurrences() {
        pendingOccurrences?.cancel()
        pendingOccurrences = nil
        guard let at = nameAtCaret, files.indices.contains(at.file) else { return box(nil) }
        let t = files[at.file].text
        guard let places = t.occurrences(atLine: at.line, column: at.column) else {
            guard t.tokens != nil else { return }
            Task(priority: .utility) { [weak self] in
                await t.indexNames()
                guard t.hasNames, let self, self.caret.map({ self.files[$0.file].text === t }) == true else { return }
                self.updateOccurrences()
            }
            return
        }
        box(places.isEmpty ? nil : (at.file, places))
    }

    private func box(_ new: (file: Int, places: [FileText.Occurrence])?) {
        boxed = new
        for c in columns { c.code.showOccurrences(new?.places ?? [], inFile: new?.file ?? 0) }
    }

    /// Boxes the names for where the caret is now, without waiting for it to rest, so a
    /// measurement counts the work.
    func settleOccurrences() {
        guard pendingOccurrences != nil else { return }
        updateOccurrences()
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
        let p = JumpPrompt(look: look)
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
            case 0: beep(); jump = .typing(query)
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
            guard labels.contains(where: { $0.hasPrefix(t) }) else { beep(); cancelJump(); return }
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
            out += SextantCore.jumpTargets(for: query, in: lines).map { (c.code, c.code.rowStarts[rows[$0.line]] + $0.column) }
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
            if !highlightUses() { beep() }
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

    /// Puts a kept selection back, or the caret on the nearest line shown when a fold now hides
    /// the selection's line.
    private func restore(_ k: KeptSelection) {
        let code = columns.indices.contains(k.side) ? columns[k.side].code : primary
        if let r = code.rows.firstIndex(where: { $0.file == k.position.file && $0.kind == .line && $0.line == k.position.line }) {
            let range = code.charRange(ofRow: r)
            let start = range.location + min(k.column, range.length)
            code.setSelectedRange(NSRange(location: start, length: min(k.length, (code.textStorage?.length ?? start) - start)))
        } else if let r = nearestLineRow(toHidden: k.position, in: code) {
            code.setSelectedRange(NSRange(location: code.landingIndex(ofRow: r), length: 0))
        } else {
            return
        }
        activeColumn = code
        markActiveColumn()
    }

    /// Returns the line row beside the fold that hides a line, on the side nearer the line.
    private func nearestLineRow(toHidden p: ReaderPosition, in code: CodeView) -> Int? {
        let rows = code.rows
        guard let fold = rows.firstIndex(where: { r in
            if case .fold(let range) = r.kind { return r.file == p.file && range.contains(p.line) }
            return false
        }) else { return nil }
        func lineRow(_ r: Int) -> Int? { rows.indices.contains(r) && rows[r].file == p.file && rows[r].kind == .line ? r : nil }
        let candidates = [lineRow(fold - 1), lineRow(fold + 1)].compactMap { $0 }
        return candidates.min { abs(rows[$0].line - p.line) < abs(rows[$1].line - p.line) }
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

    /// Returns where a line number is in the text shown of a file: the line, or the nearest line
    /// after it.
    func position(of line: SideLine, inFile fi: Int = 0) -> ReaderPosition? {
        guard files.indices.contains(fi), let i = files[fi].text.index(ofLine: line.number, old: line.old) else { return nil }
        return ReaderPosition(file: fi, line: i)
    }

    /// Returns the line number at a position in the text shown of a file.
    func sideLine(at p: ReaderPosition) -> SideLine? {
        guard files.indices.contains(p.file) else { return nil }
        return files[p.file].text.lineNumber(at: p.line)
    }

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

    /// Returns the row showing a line.
    ///
    /// - Parameter unfolding: Whether to open the fold hiding the line, as going to a line does,
    ///   rather than return the fold's row, as keeping the view in place does.
    func row(for p: ReaderPosition, in code: CodeView, unfolding: Bool = true) -> Int? {
        let rows = code.rows
        if let exact = rows.firstIndex(where: { $0.file == p.file && $0.kind == .line && $0.line == p.line }) { return exact }
        if let fold = rows.firstIndex(where: { r in
            if case .fold(let range) = r.kind { return r.file == p.file && range.contains(p.line) }
            return false
        }), case .fold(let range) = rows[fold].kind {
            guard unfolding else { return fold }
            files[p.file].unfolded.insert(range.lowerBound)
            reload(keepPosition: false)
            return code.rows.firstIndex { $0.file == p.file && $0.kind == .line && $0.line == p.line }
        }
        return rows.firstIndex { $0.file == p.file && $0.kind == .line && $0.line >= p.line } ?? rows.firstIndex { $0.file == p.file }
    }

    /// Scrolls to a line, putting it a quarter of the way down unless `offset` places it.
    ///
    /// - Parameters:
    ///   - select: Whether to put the caret on the line too.
    ///   - unfolding: Whether to open the fold hiding the line, rather than scroll to the fold.
    func scroll(to p: ReaderPosition, animated: Bool, offset: CGFloat? = nil, select: Bool = false, unfolding: Bool = true) {
        guard let r = row(for: p, in: primary, unfolding: unfolding) else { return }
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

    /// Whether each row of a layout is part of a change, on either side of side by side.
    private func changedRows(_ layout: Layout) -> [Bool] {
        let files = self.files
        func changed(_ r: Row) -> Bool {
            r.kind == .line && files[r.file].text.lines[r.line].kind != .context
        }
        guard let right = layout.right else { return layout.left.map(changed) }
        return zip(layout.left, right).map { changed($0) || changed($1) }
    }

    /// The rows where each run of changed lines starts, kept from the last reload.
    private var changeStops: [Int] = []

    /// The row moves between changes start from: the caret's, or a quarter of the way down the
    /// view when the caret is out of sight.
    private var navigationRow: Int? {
        let code = primary
        return caretInView ? caretRow : row(atY: code.visibleRect.minY + code.visibleRect.height * 0.25 + 1, in: code)
    }

    /// Whether this is the pane the window's commands act on, which shows its change counter.
    var isFocusedPane = true {
        didSet {
            header.isFocusedPane = isFocusedPane
            updateChangeCounter()
        }
    }

    private func updateChangeCounter() {
        changeCounter.isHidden = !isFocusedPane || stack.isHidden || changeStops.isEmpty
        guard !changeCounter.isHidden else { return }
        let from = navigationRow
        changeCounter.show(from.map { changeOrdinal(atRow: $0, starts: changeStops) } ?? 0, of: changeStops.count,
                           canGoBack: changeStop(-1, from: from) != nil, canGoForward: changeStop(1, from: from) != nil)
    }

    /// The row where the next or previous change starts, past a row.
    ///
    /// - Parameters:
    ///   - dir: 1 for the next change, -1 for the previous one.
    ///   - from: The row to move from, usually the navigation row.
    private func changeStop(_ dir: Int, from: Int?) -> Int? {
        guard let from else { return nil }
        return dir > 0 ? changeStops.first { $0 > from } : changeStops.last { $0 < from }
    }

    /// Moves to the next or previous change from the navigation row.
    ///
    /// - Returns: False if there is no change in that direction.
    @discardableResult
    func nextChange(_ dir: Int) -> Bool {
        guard let r = changeStop(dir, from: navigationRow) else { return false }
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
        guard !overview, let f = files.first?.text, !f.lines.isEmpty else { return false }
        if changedOnly { return stepChangedDefinition(dir, in: f) }
        let here = caret.map { f.positions.newSideHalfLine(at: $0.line) } ?? (currentNewLine ?? 0) * 2
        let starts = Set(header.definitions.map(\.nameLine)).sorted()
        guard let next = dir > 0 ? starts.first(where: { 2 * $0 > here }) : starts.last(where: { 2 * $0 < here }),
              let i = f.index(ofLine: next + 1), let r = row(for: ReaderPosition(file: 0, line: i), in: primary) else { return false }
        land(onRow: r, animated: true)
        return true
    }

    private func stepChangedDefinition(_ dir: Int, in f: FileText) -> Bool {
        let here = caret?.line ?? topPosition?.line ?? 0
        let starts = changedDefinitions(in: f.outline ?? []).compactMap { d -> Int? in
            let old = d.change == .deleted
            return f.positions.index(ofLine: d.line + 1, old: old)
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

    /// Whether the active column is the old side of two, nil with one column.
    var selectionIsOld: Bool? { columns.count == 2 ? activeCode === columns[0].code : nil }

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
        guard !overview, let f = files.first?.text, !f.lines.isEmpty else { return nil }
        let p = (caretInView ? caret : nil) ?? topPosition
        return p.map { f.positions.newSideLine(at: min($0.line, f.lines.count - 1)) }
    }

    func updateHeader() {
        updateChangeCounter()
        let style = primary.style
        if overview {
            header.update(path: nil, files: files, current: currentFile, style: style)
        } else if let f = files.first {
            header.update(path: f.file.path, files: files, current: 0, style: style)
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
        caretMovedAmongNames()
        delegate?.readerCaretMoved(self)
    }

    func codeViewMenu(_ v: CodeView, row: Int?) -> NSMenu? {
        let r = row.map { v.rows[$0] }
        return delegate?.readerMenu(self, file: r?.file, line: r?.kind == .line ? r?.line : nil)
    }
}

/// The capsule a jump shows over the code: what to type, then what's been typed.
@MainActor
final class JumpPrompt: NSView {
    private let text = NSTextField(labelWithString: "")

    init(look: any Look) {
        super.init(frame: .zero)
        let content = NSView()
        text.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            text.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            text.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            text.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
        pin(look.floating(content, cornerRadius: 16))
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
