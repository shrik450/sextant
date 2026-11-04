import AppKit
import RevueCore

extension NSAttributedString.Key {
    /// The attribute that marks link targets inside the reader (folds, gaps, file headers, notes).
    static let revueAction = NSAttributedString.Key("RevueAction")
}

/// What a click on a fold, gap, header or note asks for.
enum ReaderAction: Hashable {
    case unfold(file: Int, at: Int)
    case openFile(file: Int, line: Int?)
    case editNote(UUID)
}

/// Rendering settings shared by the text and its gutter.
@MainActor
struct Style {
    var theme: Theme
    var font: NSFont
    var boldFont: NSFont
    var lineHeight: CGFloat
    var tabInterval: CGFloat
    var digitWidth: CGFloat

    static func current(for appearance: NSAppearance) -> Style {
        let a = Appearance.shared
        let font = a.font
        var bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        if bold == font { bold = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .semibold) }
        let digit = ("0" as NSString).size(withAttributes: [.font: font]).width
        return Style(theme: a.theme(for: appearance), font: font, boldFont: bold, lineHeight: round(font.pointSize * 1.6),
                     tabInterval: digit * CGFloat(a.tabWidth), digitWidth: digit)
    }

    func paragraph(height: CGFloat? = nil, spacingBefore: CGFloat = 0) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        let h = height ?? lineHeight
        p.minimumLineHeight = h
        p.maximumLineHeight = h
        p.paragraphSpacingBefore = spacingBefore
        p.tabStops = []
        p.defaultTabInterval = tabInterval
        p.lineBreakMode = .byCharWrapping
        return p
    }

    var baselineOffset: CGFloat { max(0, (lineHeight - (font.ascender - font.descender)) / 2) }
    var headerHeight: CGFloat { round(lineHeight * 1.7) }
}

/// The text for one column of the reader, with each row's starting offset.
struct RenderedText {
    var string: NSAttributedString
    /// The UTF-16 offset where each row starts.
    var rowStarts: [Int]
}

/// Renders rows as the text for one column of the reader.
///
/// - Parameter side: 0 or 1 for the columns of side-by-side, or -1 for a single column.
@MainActor
func render(_ rows: [Row], side: Int, files: [FileState], notes: [UUID: Note], style: Style) -> RenderedText {
    let t = style.theme
    let text = NSMutableAttributedString()
    var starts: [Int] = []
    starts.reserveCapacity(rows.count)
    let base: [NSAttributedString.Key: Any] = [
        .font: style.font, .foregroundColor: t.fg, .paragraphStyle: style.paragraph(),
        .baselineOffset: style.baselineOffset, .ligature: 0,
    ]
    let muted = base.merging([.foregroundColor: t.fgMuted]) { $1 }

    var plain = ""
    var lineRanges: [(row: Int, range: NSRange)] = []
    var extras: [(NSRange, [NSAttributedString.Key: Any])] = []
    var offset = 0
    for (ri, row) in rows.enumerated() {
        starts.append(offset)
        let s: String
        var attrs: [NSAttributedString.Key: Any]?
        switch row.kind {
        case .line:
            s = displayText(files[row.file].lines[row.line].text)
        case .filler:
            s = ""
        case .fold(let r):
            s = "⋯  \(r.count) unchanged lines"
            attrs = muted.merging([.revueAction: ReaderAction.unfold(file: row.file, at: r.lowerBound), .cursor: NSCursor.pointingHand]) { $1 }
        case .gap:
            s = "⋯"
            attrs = muted.merging([.revueAction: ReaderAction.openFile(file: row.file, line: row.line), .cursor: NSCursor.pointingHand]) { $1 }
        case .header:
            let f = files[row.file]
            s = f.diff.change.oldPath != f.path && f.diff.change.isRename ? "\(f.diff.change.oldPath) → \(f.path)" : f.path
            attrs = base.merging([.font: style.boldFont, .paragraphStyle: style.paragraph(height: style.headerHeight, spacingBefore: ri == 0 ? 0 : style.lineHeight),
                                  .baselineOffset: max(0, (style.headerHeight - (style.font.ascender - style.font.descender)) / 2),
                                  .revueAction: ReaderAction.openFile(file: row.file, line: nil), .cursor: NSCursor.pointingHand]) { $1 }
        case .notice(let n):
            s = n
            attrs = muted
        case .note(let id):
            let anchoredSide = files[row.file].lines[row.line].kind == .deleted ? 0 : 1
            s = side < 0 || side == anchoredSide ? (notes[id]?.text ?? "").replacingOccurrences(of: "\n", with: "\u{2028}") : ""
            attrs = base.merging([.font: NSFont.systemFont(ofSize: style.font.pointSize), .revueAction: ReaderAction.editNote(id), .cursor: NSCursor.pointingHand]) { $1 }
        }
        plain += s
        let len = s.utf16.count
        if row.kind == .line { lineRanges.append((ri, NSRange(location: offset, length: len))) }
        if let attrs { extras.append((NSRange(location: offset, length: len + 1), attrs)) }
        plain += "\n"
        offset += len + 1
    }
    text.append(NSAttributedString(string: plain, attributes: base))
    for (r, a) in extras where NSMaxRange(r) <= text.length { text.setAttributes(a, range: r) }

    for (ri, range) in lineRanges {
        let row = rows[ri]
        let f = files[row.file]
        if let toks = f.tokens?[row.line] {
            for tok in toks where tok.range.location < range.length {
                let r = NSRange(location: range.location + tok.range.location, length: min(tok.range.length, range.length - tok.range.location))
                text.addAttribute(.foregroundColor, value: t.syntax(tok.kind), range: r)
            }
        }
        let kind = f.lines[row.line].kind
        if kind != .context {
            let color = kind == .added ? t.color("addWord") : t.color("delWord")
            for w in f.wordRanges(row.line) where NSMaxRange(w) <= range.length {
                text.addAttribute(.backgroundColor, value: color, range: NSRange(location: range.location + w.location, length: w.length))
            }
        }
    }
    return RenderedText(string: text, rowStarts: starts)
}

/// Replaces control characters other than tab with their Unicode pictures, so they're visible.
private func displayText(_ s: String) -> String {
    guard s.unicodeScalars.contains(where: { $0.value < 32 && $0.value != 9 }) else { return s }
    return String(String.UnicodeScalarView(s.unicodeScalars.map { $0.value < 32 && $0.value != 9 ? UnicodeScalar(0x2400 + $0.value)! : $0 }))
}

@MainActor
protocol CodeViewDelegate: AnyObject {
    func codeView(_ v: CodeView, perform action: ReaderAction)
    func codeView(_ v: CodeView, jumpToDefinitionOf word: String, row: Int)
    func codeViewMenu(_ v: CodeView, row: Int?) -> NSMenu?
}

/// One read-only column of code.
///
/// The text system does selection, find, copy and accessibility; this adds full-width line
/// backgrounds and maps text back to rows.
@MainActor
final class CodeView: NSTextView {
    weak var codeDelegate: CodeViewDelegate?
    var rows: [Row] = []
    var rowStarts: [Int] = []
    var files: [FileState] = []
    var style = Style.current(for: NSAppearance(named: .aqua)!)
    /// The column's side: 0 for the old side (or the only column), 1 for the new side.
    var side = 0

    static func make() -> CodeView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let v = CodeView(frame: .zero, textContainer: container)
        v.isEditable = false
        v.isSelectable = true
        v.isRichText = true
        v.importsGraphics = false
        v.usesFindBar = true
        v.isIncrementalSearchingEnabled = true
        v.isHorizontallyResizable = true
        v.isVerticallyResizable = true
        v.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        v.autoresizingMask = [.width]
        v.textContainerInset = NSSize(width: 10, height: 6)
        v.allowsUndo = false
        v.displaysLinkToolTips = false
        return v
    }

    var wraps = false {
        didSet {
            guard let c = textContainer else { return }
            c.widthTracksTextView = wraps
            isHorizontallyResizable = !wraps
            if wraps {
                fitToUncoveredWidth()
            } else {
                c.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            }
        }
    }

    /// The width of the clip view that the floating gutter doesn't cover.
    private var uncoveredWidth: CGFloat? {
        guard let clip = enclosingScrollView?.contentView else { return nil }
        return clip.bounds.width - clip.contentInsets.left - clip.contentInsets.right
    }

    /// Narrows wrapped text to the width beside the gutter, after the gutter or window changes size.
    func fitToUncoveredWidth() {
        setFrameSize(frame.size)
    }

    override func setFrameSize(_ newSize: NSSize) {
        guard wraps, let width = uncoveredWidth else { return super.setFrameSize(newSize) }
        super.setFrameSize(NSSize(width: width, height: newSize.height))
    }

    func setContent(_ r: RenderedText, rows: [Row], files: [FileState]) {
        self.rows = rows
        self.files = files
        rowStarts = r.rowStarts
        textStorage?.setAttributedString(r.string)
        backgroundColor = style.theme.canvas
        selectedTextAttributes = [.backgroundColor: style.theme.color("selection")]
        linkTextAttributes = [:]
        needsDisplay = true
    }

    func row(at charIndex: Int) -> Int? {
        guard !rowStarts.isEmpty else { return nil }
        var lo = 0, hi = rowStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if rowStarts[mid] <= charIndex { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    func charRange(ofRow r: Int) -> NSRange {
        let start = rowStarts[r]
        let end = r + 1 < rowStarts.count ? rowStarts[r + 1] - 1 : (textStorage?.length ?? start)
        return NSRange(location: start, length: max(0, end - start))
    }

    /// The rect of a row in view coordinates.
    func rect(ofRow r: Int) -> NSRect {
        guard let lm = layoutManager, let tc = textContainer, r < rowStarts.count else { return .zero }
        let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: rowStarts[r], length: 0), actualCharacterRange: nil)
        var rect = lm.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        if glyphs.location >= lm.numberOfGlyphs { rect = lm.extraLineFragmentRect }
        _ = tc
        rect.origin.y += textContainerOrigin.y
        return rect
    }

    /// Calls `body` with each row that intersects `rect` and the rect it takes up, covering all of
    /// its wrapped fragments.
    func visibleRows(in rect: NSRect, _ body: (Int, NSRect) -> Void) {
        guard let lm = layoutManager, let tc = textContainer else { return }
        let origin = textContainerOrigin
        var glyphs = lm.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: tc)
        if let first = row(at: lm.characterIndexForGlyph(at: glyphs.location)) {
            let start = lm.glyphIndexForCharacter(at: rowStarts[first])
            glyphs = NSRange(location: start, length: NSMaxRange(glyphs) - start)
        }
        var spans: [(row: Int, rect: NSRect)] = []
        lm.enumerateLineFragments(forGlyphRange: glyphs) { frag, _, _, range, _ in
            guard let r = self.row(at: lm.characterIndexForGlyph(at: range.location)) else { return }
            let f = frag.offsetBy(dx: 0, dy: origin.y)
            if let last = spans.last, last.row == r { spans[spans.count - 1].rect = last.rect.union(f) } else { spans.append((r, f)) }
        }
        if lm.extraLineFragmentRect.height > 0, let last = rows.indices.last, rowStarts[last] >= (textStorage?.length ?? 0) {
            spans.append((last, lm.extraLineFragmentRect.offsetBy(dx: 0, dy: origin.y)))
        }
        for s in spans { body(s.row, s.rect) }
    }

    func line(ofRow r: Int) -> DiffLine? {
        guard r < rows.count, rows[r].kind == .line else { return nil }
        return files[rows[r].file].lines[rows[r].line]
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let t = style.theme
        visibleRows(in: rect) { r, frag in
            let full = NSRect(x: rect.minX, y: frag.minY, width: rect.width, height: frag.height)
            switch rows[r].kind {
            case .line:
                switch line(ofRow: r)?.kind {
                case .added?: t.color("addLine").setFill(); full.fill()
                case .deleted?: t.color("delLine").setFill(); full.fill()
                default: break
                }
            case .filler:
                t.color("emptyLine").setFill(); full.fill()
            case .fold, .gap:
                t.color("hunkLine").setFill(); full.fill()
            case .header:
                let band = NSRect(x: full.minX, y: full.maxY - style.headerHeight, width: full.width, height: style.headerHeight)
                t.color("header").setFill(); band.fill()
                t.border.setFill()
                NSRect(x: full.minX, y: band.minY, width: full.width, height: 1).fill()
                NSRect(x: full.minX, y: band.maxY - 1, width: full.width, height: 1).fill()
            case .note:
                t.color("attention").withAlphaComponent(0.10).setFill(); full.fill()
                t.color("attention").withAlphaComponent(0.7).setFill()
                NSRect(x: bounds.minX + textContainerInset.width - 6, y: full.minY + 2, width: 2, height: full.height - 4).fill()
            case .notice:
                break
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let ci = characterIndexForInsertion(at: p)
        if ci < (textStorage?.length ?? 0), let action = textStorage?.attribute(.revueAction, at: ci, effectiveRange: nil) as? ReaderAction,
           let r = row(at: ci), rect(ofRow: r).contains(NSPoint(x: rect(ofRow: r).minX, y: p.y)) {
            codeDelegate?.codeView(self, perform: action)
            return
        }
        if event.modifierFlags.contains(.command), let r = row(at: ci), rows[r].kind == .line {
            if let range = identifier(at: ci), let word = textStorage?.attributedSubstring(from: range).string {
                setSelectedRange(range)
                codeDelegate?.codeView(self, jumpToDefinitionOf: word, row: r)
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        let r = row(at: characterIndexForInsertion(at: p))
        let m = codeDelegate?.codeViewMenu(self, row: r) ?? NSMenu()
        if selectedRange().length > 0 {
            m.insertItem(.separator(), at: 0)
            m.insertItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "", at: 0)
        }
        return m
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        if mods.isEmpty, event.charactersIgnoringModifiers == " " {
            event.modifierFlags.contains(.shift) ? scrollPageUp(nil) : scrollPageDown(nil)
            return
        }
        if mods.isEmpty, NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return }
        super.keyDown(with: event)
    }

    /// Returns the range of the identifier (letters, digits, `_`, `$`) at or just before a
    /// character index.
    func identifier(at index: Int) -> NSRange? {
        guard let s = textStorage?.string as NSString?, s.length > 0 else { return nil }
        func isIdent(_ i: Int) -> Bool {
            guard i >= 0, i < s.length, let u = UnicodeScalar(s.character(at: i)) else { return false }
            return CharacterSet.alphanumerics.contains(u) || u == "_" || u == "$"
        }
        var i = min(index, s.length - 1)
        if !isIdent(i) { i -= 1 }
        guard isIdent(i) else { return nil }
        var lo = i, hi = i
        while isIdent(lo - 1) { lo -= 1 }
        while isIdent(hi + 1) { hi += 1 }
        return NSRange(location: lo, length: hi - lo + 1)
    }

    /// Copies only source text, leaving out fillers, folds, headers and notes.
    override func copy(_ sender: Any?) {
        let sel = selectedRange()
        guard sel.length > 0, let storage = textStorage, let first = row(at: sel.location), let last = row(at: max(sel.location, NSMaxRange(sel) - 1)) else { return }
        var out: [String] = []
        for r in first...last {
            let kind = rows[r].kind
            guard kind == .line else { continue }
            let rr = NSIntersectionRange(charRange(ofRow: r), sel)
            let whole = charRange(ofRow: r)
            if rr.length == 0 && !(sel.location <= whole.location && NSMaxRange(sel) > NSMaxRange(whole)) && whole.length > 0 { continue }
            out.append(storage.attributedSubstring(from: rr).string)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(out.joined(separator: "\n"), forType: .string)
    }

    /// The row indices of the selected source lines, for references and notes.
    var selectedRows: [Int] {
        let sel = selectedRange()
        guard let first = row(at: sel.location) else { return [] }
        let last = sel.length > 0 ? row(at: NSMaxRange(sel) - 1) ?? first : first
        return (first...last).filter { rows[$0].kind == .line }
    }
}

/// The line numbers, change bars and note markers beside a code view.
@MainActor
final class Gutter: NSRulerView {
    var code: CodeView { clientView as! CodeView }
    /// The number of line number columns: 2 for old and new numbers (unified view of a change),
    /// or 1.
    var columns = 2
    var noteLines: Set<String> = []
    var blame: Blame?

    init(code: CodeView, scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = code
        scrollView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrollViewResized), name: NSView.frameDidChangeNotification, object: scrollView)
    }

    @objc private func scrollViewResized() { updateThickness() }

    required init(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// The width of one column of line numbers, fitting the largest line number.
    private var numberColumnWidth: CGFloat {
        let maxNo = code.files.reduce(1) { max($0, $1.lines.last.map { max($0.oldNo, $0.newNo) } ?? 1) }
        return CGFloat(max(3, String(maxNo).count)) * code.style.digitWidth + 12
    }

    /// The width of the blame column, which narrows so the code keeps at least half the reader.
    private var blameWidth: CGFloat {
        guard blame != nil else { return 0 }
        let digit = code.style.digitWidth
        let room = (scrollView?.frame.width ?? .infinity) / 2 - numberColumnWidth * CGFloat(columns) - 10
        return max(8 * digit, min(28 * digit, room)).rounded()
    }

    /// Fits the gutter to its line numbers, blame and the reader's width, keeping the code's
    /// horizontal scroll position.
    func updateThickness() {
        let thickness = ceil(blameWidth + numberColumnWidth * CGFloat(columns) + 10)
        if thickness != ruleThickness, let scrollView {
            let clip = scrollView.contentView
            let scrolledX = max(0, clip.bounds.minX + clip.contentInsets.left)
            ruleThickness = thickness
            scrollView.tile()
            code.fitToUncoveredWidth()
            clip.setBoundsOrigin(NSPoint(x: scrolledX - clip.contentInsets.left, y: clip.bounds.minY))
            scrollView.reflectScrolledClipView(clip)
        }
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        let s = code.style, t = s.theme
        t.canvas.setFill()
        bounds.fill()
        t.border.withAlphaComponent(0.5).setFill()
        NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()

        let col = numberColumnWidth
        let blameWidth = blameWidth
        let numAttrs: [NSAttributedString.Key: Any] = [.font: s.font, .foregroundColor: t.color("lineNumber")]
        let visible = code.visibleRect
        let offset = convert(NSPoint.zero, from: code).y
        var lastBlame: String?

        code.visibleRows(in: visible) { r, frag in
            let y = frag.minY + offset
            let row = code.rows[r]
            guard row.kind == .line, let line = code.line(ofRow: r) else {
                if case .filler = row.kind {
                    t.color("emptyLine").setFill()
                    NSRect(x: blameWidth, y: y, width: bounds.width - blameWidth - 1, height: frag.height).fill()
                }
                lastBlame = nil
                return
            }
            let band = NSRect(x: blameWidth, y: y, width: bounds.width - blameWidth - 1, height: frag.height)
            switch line.kind {
            case .added: t.color("addNum").setFill(); band.fill()
            case .deleted: t.color("delNum").setFill(); band.fill()
            case .context: break
            }
            let textY = y + (s.lineHeight - (s.font.ascender - s.font.descender)) / 2
            func number(_ n: Int, column: Int) {
                guard n > 0 else { return }
                let str = String(n) as NSString
                let w = CGFloat(str.length) * s.digitWidth
                str.draw(at: NSPoint(x: blameWidth + col * CGFloat(column + 1) - 8 - w, y: textY), withAttributes: numAttrs)
            }
            if columns == 2 {
                number(line.oldNo, column: 0)
                number(line.newNo, column: 1)
            } else {
                number(line.kind == .deleted ? line.oldNo : line.newNo, column: 0)
            }
            if line.kind != .context {
                (line.kind == .added ? t.color("success") : t.color("danger")).setFill()
                NSRect(x: bounds.maxX - 4, y: y, width: 3, height: frag.height).fill()
            }
            if let blame, line.kind != .deleted, let c = blame.commit(forLine: line.newNo - 1) {
                let label = c.isUncommitted ? "Not committed" : "\(String(c.oid.prefix(7)))  \(c.author)"
                if label != lastBlame {
                    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: s.font.pointSize - 1), .foregroundColor: t.fgMuted]
                    let date = c.isUncommitted ? "" : compactDate(c.date)
                    let dw = (date as NSString).size(withAttributes: attrs).width
                    let oid = c.isUncommitted ? label : String(c.oid.prefix(7))
                    let oidWidth = (oid as NSString).size(withAttributes: attrs).width
                    let showsDate = blameWidth - dw - 20 >= oidWidth
                    let room = blameWidth - (showsDate ? dw + 20 : 12)
                    let shown = room >= oidWidth + 4 * s.digitWidth ? label : oid
                    (shown as NSString).draw(with: NSRect(x: 6, y: textY, width: room, height: s.lineHeight),
                                             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
                    if showsDate { (date as NSString).draw(at: NSPoint(x: blameWidth - 8 - dw, y: textY), withAttributes: attrs) }
                    t.border.withAlphaComponent(0.4).setFill()
                    NSRect(x: 0, y: y, width: blameWidth, height: 1).fill()
                }
                lastBlame = label
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let inCode = code.convert(p, from: self)
        let ci = code.characterIndexForInsertion(at: NSPoint(x: code.textContainerOrigin.x, y: inCode.y))
        guard let r = code.row(at: ci) else { return }
        let range = code.charRange(ofRow: r)
        if event.modifierFlags.contains(.shift) {
            code.setSelectedRange(NSUnionRange(code.selectedRange(), NSRange(location: range.location, length: range.length + 1)))
        } else {
            code.setSelectedRange(NSRange(location: range.location, length: range.length + 1))
        }
        code.window?.makeFirstResponder(code)
        if p.x < blameWidth, let line = code.line(ofRow: r), line.kind != .deleted,
           let c = blame?.commit(forLine: line.newNo - 1), !c.isUncommitted {
            onBlameClick?(c, line.newNo)
        }
    }

    var onBlameClick: ((Blame.Commit, Int) -> Void)?
}
