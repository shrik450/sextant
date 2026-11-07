import AppKit
import SextantCore

extension NSAttributedString.Key {
    /// The attribute that marks link targets inside the reader (folds, gaps, file headers, notes).
    static let sextantAction = NSAttributedString.Key("SextantAction")
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
    /// How opaque the pane's canvas is, as its look sets it.
    var canvasOpacity: CGFloat = 1

    /// The pane's fill: the canvas at its opacity, so what's behind the strip can show through
    /// the pane. Each part of the pane is filled with it once.
    var canvasFill: NSColor { theme.canvas.withAlphaComponent(canvasOpacity) }

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

    /// The text of an "N unchanged lines" pill: the interface font, a step smaller than the code.
    var pillFont: NSFont { .systemFont(ofSize: font.pointSize - 1, weight: .medium) }
    /// The pill's padding at each end, around its icon and text.
    var pillPadding: CGFloat { 9 }
    /// The width of the pill's expand icon and the gap after it.
    var pillIcon: (width: CGFloat, gap: CGFloat) { (round(font.pointSize * 0.85), 5) }

    /// The paragraph of a pill's row, which leaves room before the text for the pill's padding
    /// and icon.
    var pillParagraph: NSParagraphStyle {
        let p = paragraph().mutableCopy() as! NSMutableParagraphStyle
        p.firstLineHeadIndent = pillPadding + pillIcon.width + pillIcon.gap
        return p
    }

    var pillBaselineOffset: CGFloat { max(0, (lineHeight - (pillFont.ascender - pillFont.descender)) / 2) }
}

/// The text for one column of the reader, with each row's starting offset.
struct RenderedText {
    var string: NSAttributedString
    /// The UTF-16 offset where each row starts.
    var rowStarts: [Int]
}

/// Renders rows as the text for one column of the reader, one row to a line.
///
/// The last row has no newline after it, which would lay out an empty line below it.
///
/// - Parameter side: 0 or 1 for the columns of side-by-side, or -1 for a single column.
@MainActor
func render(_ rows: [Row], side: Int, files: [ShownFile], notes: [UUID: Note], style: Style) -> RenderedText {
    let t = style.theme
    let text = NSMutableAttributedString()
    var starts: [Int] = []
    starts.reserveCapacity(rows.count)
    let base: [NSAttributedString.Key: Any] = [
        .font: style.font, .foregroundColor: t.fg, .paragraphStyle: style.paragraph(),
        .baselineOffset: style.baselineOffset, .ligature: 0,
    ]
    let muted = base.merging([.foregroundColor: t.fgMuted]) { $1 }
    let pill = muted.merging([.font: style.pillFont, .paragraphStyle: style.pillParagraph,
                              .baselineOffset: style.pillBaselineOffset, .cursor: NSCursor.pointingHand]) { $1 }

    var plain = ""
    var extras: [(NSRange, [NSAttributedString.Key: Any])] = []
    var offset = 0
    for (ri, row) in rows.enumerated() {
        starts.append(offset)
        let s: String
        var attrs: [NSAttributedString.Key: Any]?
        switch row.kind {
        case .line:
            s = displayText(files[row.file].text.lines[row.line].text)
        case .filler:
            s = ""
        case .fold(let r):
            s = unchangedLabel(r.count)
            attrs = pill.merging([.sextantAction: ReaderAction.unfold(file: row.file, at: r.lowerBound)]) { $1 }
        case .gap(let hidden):
            s = unchangedLabel(hidden)
            attrs = pill.merging([.sextantAction: ReaderAction.openFile(file: row.file, line: row.line)]) { $1 }
        case .header:
            let f = files[row.file].file
            s = f.diff.change.oldPath != f.path && f.diff.change.isRename ? "\(f.diff.change.oldPath) → \(f.path)" : f.path
            attrs = base.merging([.font: style.boldFont, .paragraphStyle: style.paragraph(height: style.headerHeight, spacingBefore: ri == 0 ? 0 : style.lineHeight),
                                  .baselineOffset: max(0, (style.headerHeight - (style.font.ascender - style.font.descender)) / 2),
                                  .sextantAction: ReaderAction.openFile(file: row.file, line: nil), .cursor: NSCursor.pointingHand]) { $1 }
        case .notice(let n):
            s = n
            attrs = muted
        case .note(let id):
            let anchoredSide = files[row.file].text.lines[row.line].kind == .deleted ? 0 : 1
            s = side < 0 || side == anchoredSide ? (notes[id]?.text ?? "").replacingOccurrences(of: "\n", with: "\u{2028}") : ""
            attrs = base.merging([.font: NSFont.systemFont(ofSize: style.font.pointSize), .sextantAction: ReaderAction.editNote(id), .cursor: NSCursor.pointingHand]) { $1 }
        }
        plain += s
        let len = s.utf16.count
        if let attrs { extras.append((NSRange(location: offset, length: len + 1), attrs)) }
        if ri < rows.count - 1 { plain += "\n" }
        offset += len + 1
    }
    text.append(NSAttributedString(string: plain, attributes: base))
    let whole = NSRange(location: 0, length: text.length)
    for (r, a) in extras { text.setAttributes(a, range: NSIntersectionRange(r, whole)) }
    return RenderedText(string: text, rowStarts: starts)
}

private func unchangedLabel(_ count: Int) -> String {
    count == 1 ? "1 unchanged line" : "\(count) unchanged lines"
}

/// Replaces control characters other than tab with their Unicode pictures, so they're visible.
func displayText(_ s: String) -> String {
    guard s.unicodeScalars.contains(where: { $0.value < 32 && $0.value != 9 }) else { return s }
    return String(String.UnicodeScalarView(s.unicodeScalars.map { $0.value < 32 && $0.value != 9 ? UnicodeScalar(0x2400 + $0.value)! : $0 }))
}

@MainActor
protocol CodeViewDelegate: AnyObject {
    func codeView(_ v: CodeView, perform action: ReaderAction)
    func codeView(_ v: CodeView, jumpToDefinitionOf word: String, row: Int)
    func codeViewMenu(_ v: CodeView, row: Int?) -> NSMenu?
    func codeViewCaretMoved(_ v: CodeView)
    /// Offers a key press to the reader before the view handles it, for keys that span columns
    /// such as typing a jump.
    ///
    /// - Returns: Whether the reader handled it.
    func codeView(_ v: CodeView, intercept event: NSEvent) -> Bool
    func codeViewAddNote(_ v: CodeView)
    /// Tells the delegate the view took the keyboard.
    func codeViewFocused(_ v: CodeView)
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
    var files: [ShownFile] = []
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
        v.isContinuousSpellCheckingEnabled = false
        v.isGrammarCheckingEnabled = false
        v.isAutomaticSpellingCorrectionEnabled = false
        v.isAutomaticLinkDetectionEnabled = false
        v.isAutomaticDataDetectionEnabled = false
        v.isAutomaticTextCompletionEnabled = false
        v.enabledTextCheckingTypes = 0
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

    func setContent(_ r: RenderedText, rows: [Row], files: [ShownFile]) {
        hoveredPill = nil
        self.rows = rows
        self.files = files
        rowStarts = r.rowStarts
        textStorage?.setAttributedString(r.string)
        colored = []
        occurrences = []
        lineRows = [:]
        backgroundColor = .clear
        selectedTextAttributes = [.backgroundColor: style.theme.color("selection")]
        linkTextAttributes = [:]
        needsDisplay = true
        colorVisibleRows()
    }

    /// The rows whose syntax and changed-word colors are drawn.
    private var colored = IndexSet()

    /// Colors the rows in and near the view.
    ///
    /// Colors are temporary attributes, which change how text draws without laying it out
    /// again, so coloring costs what's on screen rather than the whole text.
    func colorVisibleRows() {
        guard let lm = layoutManager, let near = rowsNearView else { return }
        for r in near where !colored.contains(r) {
            if color(row: r, lm) { colored.insert(r) }
        }
    }

    /// Colors a file's rows again, once its analysis has arrived.
    func recolor(file: Int) {
        let range = rowRange(ofFile: file)
        guard !range.isEmpty else { return }
        colored.remove(integersIn: range)
        colorVisibleRows()
    }

    /// The rows showing a file, found by bisecting, since rows are in file order.
    private func rowRange(ofFile file: Int) -> Range<Int> {
        func firstRow(_ isAtOrPast: (Int) -> Bool) -> Int {
            var lo = 0, hi = rows.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if isAtOrPast(rows[mid].file) { hi = mid } else { lo = mid + 1 }
            }
            return lo
        }
        return firstRow { $0 >= file }..<firstRow { $0 > file }
    }

    /// Whether a row in view still waits for its colors.
    var awaitsColors: Bool {
        guard let near = rowsInView else { return false }
        return near.contains { !colored.contains($0) }
    }

    private var rowsInView: ClosedRange<Int>? { rows(in: visibleRect) }

    private var rowsNearView: ClosedRange<Int>? {
        let v = visibleRect
        return rows(in: v.insetBy(dx: 0, dy: -v.height))
    }

    private func rows(in rect: NSRect) -> ClosedRange<Int>? {
        guard let lm = layoutManager, let tc = textContainer, !rows.isEmpty, let length = textStorage?.length, length > 0 else { return nil }
        let origin = textContainerOrigin
        let glyphs = lm.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        guard let first = row(at: chars.location), let last = row(at: max(chars.location, NSMaxRange(chars) - 1)) else { return nil }
        return first...last
    }

    /// Applies a row's syntax and changed-word colors, and keeps the text of its boxed names
    /// readable on their boxes.
    ///
    /// - Returns: False if the row's file is still being analyzed.
    private func color(row r: Int, _ lm: NSLayoutManager) -> Bool {
        let row = rows[r]
        guard row.kind == .line else { return true }
        let f = files[row.file].text
        let range = charRange(ofRow: r)
        let t = style.theme
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        for tok in f.tokens?[row.line] ?? [] where tok.range.location < range.length {
            let at = NSRange(location: range.location + tok.range.location, length: min(tok.range.length, range.length - tok.range.location))
            lm.addTemporaryAttribute(.foregroundColor, value: t.syntax(tok.kind), forCharacterRange: at)
        }
        let kind = f.lines[row.line].kind
        let read = kind != .context && isReadLine(row.file, row.line)
        var lineBackground = t.canvas.rgb
        var words: [NSRange] = []
        var wordColor = NSColor.clear
        if kind != .context {
            let tints = kind == .added ? (line: t.color("addLine"), word: t.color("addWord")) : (line: t.color("delLine"), word: t.color("delWord"))
            lineBackground = (read ? tints.line.asRead : tints.line).laid(over: lineBackground)
            wordColor = read ? tints.word.asRead : tints.word
            words = f.wordRanges(row.line).filter { NSMaxRange($0) <= range.length }
            for w in words {
                let at = NSRange(location: range.location + w.location, length: w.length)
                lm.addTemporaryAttribute(.backgroundColor, value: wordColor, forCharacterRange: at)
                makeReadable(at, on: wordColor.laid(over: lineBackground), lm)
            }
        }
        let occurrence = t.color("occurrence")
        for o in occurrences(onRow: r) where NSMaxRange(o.range) <= range.length {
            let under = occurrence.laid(over: lineBackground)
            makeReadable(NSRange(location: range.location + o.range.location, length: o.range.length), on: under, lm)
            for w in words {
                let both = NSIntersectionRange(w, o.range)
                guard both.length > 0 else { continue }
                makeReadable(NSRange(location: range.location + both.location, length: both.length), on: wordColor.laid(over: under), lm)
            }
        }
        return f.tokens != nil || !f.hasLanguage
    }

    /// Darkens or lightens each colour of text in `range` just enough to read on `background`,
    /// as on a changed word, whose highlight is darker than the line it's on.
    private func makeReadable(_ range: NSRange, on background: RGB, _ lm: NSLayoutManager) {
        var i = range.location
        while i < NSMaxRange(range) {
            var run = NSRange()
            let color = lm.temporaryAttribute(.foregroundColor, atCharacterIndex: i, effectiveRange: &run) as? NSColor ?? style.theme.fg
            let part = NSIntersectionRange(run, range)
            let at = part.length > 0 ? part : NSRange(location: i, length: 1)
            lm.addTemporaryAttribute(.foregroundColor, value: Self.readable(color.rgb, on: background), forCharacterRange: at)
            i = NSMaxRange(at)
        }
    }

    private struct ColorPair: Hashable {
        var text: RGB
        var background: RGB
    }

    /// Text colours already made readable, by colour and background. A theme has about a dozen
    /// text colours and four changed-word highlights, so this stays small, and each search runs
    /// once rather than on every word drawn.
    private static var readableColors: [ColorPair: NSColor] = [:]

    private static func readable(_ text: RGB, on background: RGB) -> NSColor {
        let pair = ColorPair(text: text, background: background)
        if let known = readableColors[pair] { return known }
        let color = NSColor(SextantCore.readable(text, on: background))
        readableColors[pair] = color
        return color
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

    /// The rect of a row's first line in view coordinates.
    ///
    /// Lays out the text up to the row, since positions past the laid-out text are only estimates.
    func rect(ofRow r: Int) -> NSRect {
        guard let lm = layoutManager, r < rowStarts.count else { return .zero }
        let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: rowStarts[r], length: 0), actualCharacterRange: nil)
        lm.ensureLayout(forGlyphRange: NSRange(location: 0, length: min(glyphs.location + 1, lm.numberOfGlyphs)))
        var rect = lm.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        if glyphs.location >= lm.numberOfGlyphs { rect = lm.extraLineFragmentRect }
        rect.origin.y += textContainerOrigin.y
        return rect
    }

    /// The rect of a row's first line if it's laid out, without laying out any more text.
    ///
    /// A row that isn't laid out isn't drawn either, so there's nothing of it to redraw.
    func laidOutRect(ofRow r: Int) -> NSRect? {
        guard let lm = layoutManager, r < rowStarts.count, rowStarts[r] < (textStorage?.length ?? 0) else { return nil }
        let glyph = lm.glyphIndexForCharacter(at: rowStarts[r])
        let rect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
        return rect.isEmpty ? nil : rect.offsetBy(dx: 0, dy: textContainerOrigin.y)
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
        return files[rows[r].file].text.lines[rows[r].line]
    }

    /// The caret is drawn as a highlight around the token it's on instead, so the word a lookup
    /// uses is the word you see.
    override var shouldDrawInsertionPoint: Bool { false }

    /// Whether this column highlights the caret's line, which only the column with the caret does.
    var showsCurrentLine = true { didSet { if showsCurrentLine != oldValue { needsDisplay = true } } }

    /// The row the caret is on, while nothing is selected.
    var caretRow: Int? {
        let sel = selectedRange()
        guard sel.length == 0, !rows.isEmpty else { return nil }
        return row(at: sel.location)
    }

    /// Says whether a line of a file, by file index and line index, is in a run of changes that's
    /// been read.
    var isReadLine: (Int, Int) -> Bool = { _, _ in false }

    /// The uses of a name to highlight, as ranges of the text.
    var uses: [NSRange] = [] { didSet { needsDisplay = true } }

    /// A name boxed in a row: the row, and the name's UTF-16 range in it.
    private struct RowRange: Equatable {
        var row: Int
        var range: NSRange
    }

    /// The names that name what the caret's name names, in order, drawn boxed.
    private var occurrences: [RowRange] = []

    /// The row of each of a file's lines, or -1 for a line this column doesn't show, kept for
    /// the files whose names were boxed since the text was last set.
    private var lineRows: [Int: [Int32]] = [:]

    private func rows(ofLinesIn file: Int) -> [Int32] {
        if let known = lineRows[file] { return known }
        var map = [Int32](repeating: -1, count: files[file].text.lines.count)
        for r in rowRange(ofFile: file) where rows[r].kind == .line { map[rows[r].line] = Int32(r) }
        lineRows[file] = map
        return map
    }

    /// Boxes some places in one file's lines, the ones this column shows, and unboxes the rest.
    ///
    /// Only the rows whose boxes change are colored and drawn again, so moving between names
    /// costs what changes rather than what's shown.
    func showOccurrences(_ places: [FileText.Occurrence], inFile file: Int) {
        let shown: [RowRange]
        if places.isEmpty || !files.indices.contains(file) {
            shown = []
        } else {
            let rowOfLine = rows(ofLinesIn: file)
            shown = places.compactMap { p in rowOfLine[p.line] >= 0 ? RowRange(row: Int(rowOfLine[p.line]), range: p.range) : nil }
        }
        let changed = Self.changedRows(occurrences, shown)
        occurrences = shown
        guard !changed.isEmpty else { return }
        let near = rowsNearView
        for r in changed {
            colored.remove(r)
            guard near?.contains(r) == true, let rect = laidOutBounds(ofRow: r) else { continue }
            setNeedsDisplay(NSRect(x: bounds.minX, y: rect.minY, width: bounds.width, height: rect.height))
        }
        colorVisibleRows()
    }

    /// Returns the rows whose boxes differ between two lists of boxes, each in order.
    private static func changedRows(_ a: [RowRange], _ b: [RowRange]) -> [Int] {
        var changed: [Int] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            let row = min(i < a.count ? a[i].row : .max, j < b.count ? b[j].row : .max)
            let si = i, sj = j
            while i < a.count, a[i].row == row { i += 1 }
            while j < b.count, b[j].row == row { j += 1 }
            if !a[si..<i].elementsEqual(b[sj..<j]) { changed.append(row) }
        }
        return changed
    }

    /// The boxed names in a row, found by bisecting.
    private func occurrences(onRow r: Int) -> ArraySlice<RowRange> {
        var lo = 0, hi = occurrences.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if occurrences[mid].row < r { lo = mid + 1 } else { hi = mid }
        }
        var end = lo
        while end < occurrences.count, occurrences[end].row == r { end += 1 }
        return occurrences[lo..<end]
    }

    /// The rect of all of a row's wrapped lines if it's laid out, without laying out any more
    /// text.
    private func laidOutBounds(ofRow r: Int) -> NSRect? {
        guard let first = laidOutRect(ofRow: r), let lm = layoutManager, let tc = textContainer else { return nil }
        let glyphs = lm.glyphRange(forCharacterRange: charRange(ofRow: r), actualCharacterRange: nil)
        guard glyphs.length > 0 else { return first }
        return lm.boundingRect(forGlyphRange: glyphs, in: tc).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y).union(first)
    }

    /// Draws a box behind each boxed name in some rows, as the caret's own name is boxed.
    private func drawOccurrences(onRows boxed: [Int]) {
        guard !boxed.isEmpty, let lm = layoutManager, let tc = textContainer else { return }
        style.theme.color("occurrence").setFill()
        let origin = textContainerOrigin
        for r in boxed {
            for o in occurrences(onRow: r) {
                let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: rowStarts[r] + o.range.location, length: o.range.length), actualCharacterRange: nil)
                lm.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: tc) { rect, _ in
                    let box = NSRect(x: rect.minX + origin.x - 2, y: rect.minY + origin.y + 1, width: rect.width + 4, height: min(rect.height, self.style.lineHeight) - 2)
                    NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
                }
            }
        }
    }

    /// Labels for the places a typed jump can land, as text offsets.
    var jumpLabels: [(index: Int, label: String)] = [] { didSet { needsDisplay = true } }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        if !movingVertically { goalColumn = nil }
        let before = caretRow
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        let after = caretRow
        for r in [before, after].compactMap({ $0 }) where r < rows.count {
            guard let line = laidOutRect(ofRow: r) else { continue }
            setNeedsDisplay(NSRect(x: visibleRect.minX, y: line.minY, width: visibleRect.width, height: line.height + style.lineHeight))
        }
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
        if !stillSelecting { codeDelegate?.codeViewCaretMoved(self) }
    }

    /// The rect of the token the caret is on, or of the character after it.
    var caretRect: NSRect? {
        guard let r = caretRow, rows[r].kind == .line, let lm = layoutManager, let tc = textContainer else { return nil }
        let at = selectedRange().location
        let line = charRange(ofRow: r)
        let range = identifier(at: at).flatMap { NSLocationInRange($0.location, line) ? $0 : nil }
            ?? NSRange(location: at, length: at < NSMaxRange(line) ? 1 : 0)
        let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        if range.length == 0 { rect.size.width = style.digitWidth }
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        let frag = self.rect(ofRow: r)
        return NSRect(x: rect.minX - 2, y: frag.minY + 1, width: rect.width + 4, height: min(frag.height, style.lineHeight) - 2)
    }

    /// The rect of the selected text, or `nil` while nothing is selected.
    var selectionRect: NSRect? {
        let sel = selectedRange()
        guard sel.length > 0, let lm = layoutManager, let tc = textContainer else { return nil }
        let glyphs = lm.glyphRange(forCharacterRange: sel, actualCharacterRange: nil)
        return lm.boundingRect(forGlyphRange: glyphs, in: tc).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    private func drawCaret() {
        guard showsCurrentLine, let rect = caretRect else { return }
        let focused = window?.firstResponder === self && window?.isKeyWindow == true
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        let accent = NSColor.themed("accent")
        if focused {
            accent.withAlphaComponent(0.22).setFill()
            path.fill()
            accent.setStroke()
            path.lineWidth = 1.5
        } else {
            NSColor.themed("fgMuted").withAlphaComponent(0.6).setStroke()
            path.lineWidth = 1
        }
        path.stroke()
    }

    private func drawUses(in rect: NSRect) {
        guard !uses.isEmpty, let lm = layoutManager, let tc = textContainer else { return }
        style.theme.color("attention").withAlphaComponent(0.28).setFill()
        for u in uses {
            let glyphs = lm.glyphRange(forCharacterRange: u, actualCharacterRange: nil)
            let r = lm.boundingRect(forGlyphRange: glyphs, in: tc).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            guard r.intersects(rect) else { continue }
            NSBezierPath(roundedRect: r.insetBy(dx: -1, dy: 1), xRadius: 3, yRadius: 3).fill()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !jumpLabels.isEmpty, let lm = layoutManager, let tc = textContainer else { return }
        let font = NSFont.monospacedSystemFont(ofSize: style.font.pointSize - 1, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 2
        for (index, label) in jumpLabels {
            let glyph = lm.glyphIndexForCharacter(at: index)
            let at = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            let size = (label as NSString).size(withAttributes: attrs)
            let box = NSRect(x: at.minX - 2, y: at.midY - size.height / 2 - 1, width: size.width + 6, height: size.height + 2)
            guard box.insetBy(dx: -3, dy: -3).intersects(dirtyRect) else { continue }
            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            NSColor.findHighlightColor.setFill()
            NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
            NSGraphicsContext.restoreGraphicsState()
            (label as NSString).draw(at: NSPoint(x: box.minX + 3, y: box.minY + 1), withAttributes: attrs)
        }
    }

    override func becomeFirstResponder() -> Bool {
        defer { needsDisplay = true }
        let took = super.becomeFirstResponder()
        if took { codeDelegate?.codeViewFocused(self) }
        return took
    }

    override func resignFirstResponder() -> Bool {
        defer { needsDisplay = true }
        return super.resignFirstResponder()
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let t = style.theme
        let current = showsCurrentLine ? caretRow : nil
        let focused = window?.firstResponder === self
        var boxed: [Int] = []
        visibleRows(in: rect) { r, frag in
            if !occurrences.isEmpty, !occurrences(onRow: r).isEmpty { boxed.append(r) }
            defer {
                if r == current {
                    t.color("selection").withAlphaComponent(focused ? 0.16 : 0.07).setFill()
                    NSRect(x: rect.minX, y: frag.minY, width: rect.width, height: frag.height).fill(using: .sourceOver)
                }
            }
            let full = NSRect(x: rect.minX, y: frag.minY, width: rect.width, height: frag.height)
            switch rows[r].kind {
            case .line:
                let kind = line(ofRow: r)?.kind
                guard kind == .added || kind == .deleted else { break }
                let changed = kind == .added ? t.color("addLine") : t.color("delLine")
                (isReadLine(rows[r].file, rows[r].line) ? changed.asRead : changed).setFill()
                full.fill()
            case .filler:
                t.color("emptyLine").setFill(); full.fill()
                t.color("hatch").setStroke(); full.hatch(origin: .zero)
            case .fold, .gap:
                t.color("hunkLine").setFill(); full.fill()
                drawPill(ofRow: r, in: frag)
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
        drawOccurrences(onRows: boxed)
        drawUses(in: rect)
        drawCaret()
    }

    /// The row of the "N unchanged lines" pill under the mouse, which the pill shows.
    private var pillArea: NSTrackingArea?
    private var hoveredPill: Int? {
        didSet {
            guard hoveredPill != oldValue else { return }
            for r in [oldValue, hoveredPill].compactMap({ $0 }) where r < rows.count { setNeedsDisplay(rect(ofRow: r)) }
        }
    }

    private func pillRow(at event: NSEvent) -> Int? {
        let p = convert(event.locationInWindow, from: nil)
        guard let r = row(at: characterIndexForInsertion(at: p)), r < rows.count else { return nil }
        switch rows[r].kind {
        case .fold, .gap: return r
        default: return nil
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pillArea { removeTrackingArea(pillArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        pillArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        hoveredPill = pillRow(at: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredPill = nil
    }

    /// Draws a fold or gap row's text as a capsule with an expand icon, marking where unchanged
    /// lines are hidden and that a click shows them.
    private func drawPill(ofRow r: Int, in frag: NSRect) {
        guard let lm = layoutManager, let tc = textContainer, let length = textStorage?.length else { return }
        let s = style, t = s.theme
        let end = r + 1 < rowStarts.count ? rowStarts[r + 1] - 1 : length
        let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: rowStarts[r], length: max(0, end - rowStarts[r])), actualCharacterRange: nil)
        let text = lm.boundingRect(forGlyphRange: glyphs, in: tc).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        let lead = s.pillPadding + s.pillIcon.width + s.pillIcon.gap
        let height = min(frag.height - 4, ceil(s.pillFont.pointSize * 1.6))
        let shape = NSRect(x: text.minX - lead, y: frag.midY - height / 2, width: lead + text.width + s.pillPadding, height: height)
        let capsule = NSBezierPath(roundedRect: shape, xRadius: height / 2, yRadius: height / 2)
        s.canvasFill.setFill(); capsule.fill()
        if hoveredPill == r { t.color("hover").setFill(); capsule.fill() }
        capsule.lineWidth = 0.75
        (hoveredPill == r ? t.color("pillStrokeFocused") : t.color("pillStroke")).setStroke(); capsule.stroke()
        let config = NSImage.SymbolConfiguration(pointSize: s.pillIcon.width * 0.8, weight: .semibold)
            .applying(.init(paletteColors: [hoveredPill == r ? t.fg : t.fgMuted]))
        guard let icon = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        let size = icon.size
        icon.draw(in: NSRect(x: shape.minX + s.pillPadding + (s.pillIcon.width - size.width) / 2, y: shape.midY - size.height / 2, width: size.width, height: size.height),
                  from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    override func mouseDown(with event: NSEvent) {
        lineSelectionStart = nil
        let p = convert(event.locationInWindow, from: nil)
        let ci = characterIndexForInsertion(at: p)
        if ci < (textStorage?.length ?? 0), let action = textStorage?.attribute(.sextantAction, at: ci, effectiveRange: nil) as? ReaderAction,
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
        if codeDelegate?.codeView(self, intercept: event) == true { return }
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        if mods == [.control], let c = event.charactersIgnoringModifiers {
            if c == "d" { halfPage(1); return }
            if c == "u" { halfPage(-1); return }
        }
        if mods.isEmpty, let c = event.characters {
            switch c {
            case " ": page(event.modifierFlags.contains(.shift) ? -1 : 1); return
            case "j": readLine(1); return
            case "k": readLine(-1); return
            case "w": stepName(1); return
            case "b": stepName(-1); return
            case "V": toggleLineSelection(); return
            case "\u{1b}":
                if selectedRange().length > 0 { collapseSelection(); return }
            default: break
            }
        }
        if mods.isEmpty, NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return }
        interpretKeyEvents([event])
    }

    /// The row where `V` started selecting whole lines, while it's still doing so.
    private var lineSelectionStart: Int?

    /// Starts or stops selecting whole lines from the caret's line.
    private func toggleLineSelection() {
        if lineSelectionStart != nil { collapseSelection(); return }
        guard let r = row(at: head), rows[r].kind == .line else { beep(); return }
        selectLines(from: r, to: r)
        lineSelectionStart = r
    }

    /// Selects whole rows, keeping `to` as the end that moves.
    func selectLines(from a: Int, to b: Int) {
        let lo = min(a, b), hi = max(a, b)
        let range = NSRange(location: rowStarts[lo], length: NSMaxRange(charRange(ofRow: hi)) - rowStarts[lo])
        setSelectedRange(range)
        anchorIndex = a <= b ? range.location : NSMaxRange(range)
        headIndex = a <= b ? NSMaxRange(range) : range.location
        scrollRangeToVisible(NSRange(location: rowStarts[b], length: 0))
    }

    private func collapseSelection() {
        lineSelectionStart = nil
        let r = row(at: head).flatMap { rows[$0].kind == .line ? $0 : nil }
        moveCaret(to: r.map(landingIndex(ofRow:)) ?? selectedRange().location, extend: false)
    }

    /// The text offset where the caret lands on a row: its first changed name, else its first
    /// name, else its first character that isn't a space.
    func landingIndex(ofRow r: Int) -> Int {
        let range = charRange(ofRow: r)
        guard rows[r].kind == .line, let text = textStorage?.string as NSString? else { return range.location }
        let f = files[rows[r].file].text
        let line = rows[r].line
        return range.location + min(range.length, landingColumn(in: text, range: range, tokens: f.tokens?[line] ?? [], changed: f.wordRanges(line)))
    }

    /// Moves to the next or previous line, landing on its first changed name, or extends a
    /// selection of whole lines.
    private func readLine(_ dir: Int) {
        guard let r = row(at: head), let n = lineRow(from: r, dir) else { beep(); return }
        if let start = lineSelectionStart {
            selectLines(from: start, to: n)
            lineSelectionStart = start
            return
        }
        moveCaret(to: landingIndex(ofRow: n), extend: false)
    }

    /// Moves to the next or previous name, going on to the next or previous line at either end.
    private func stepName(_ dir: Int) {
        lineSelectionStart = nil
        let h = head
        guard var r = row(at: h) else { return }
        var first = true
        let before = identifierStart(h)
        while true {
            if rows[r].kind == .line, let text = textStorage?.string as NSString? {
                let range = charRange(ofRow: r)
                let tokens = files[rows[r].file].text.tokens?[rows[r].line] ?? []
                var pick: Int?
                forEachIdentifier(in: text, range: range, tokens: tokens) { name in
                    let at = name.location + range.location
                    if dir > 0 {
                        guard first, at <= h else { pick = at; return false }
                        return true
                    }
                    guard !first || at < before else { return false }
                    pick = at
                    return true
                }
                if let pick { moveCaret(to: pick, extend: false); return }
            }
            first = false
            guard let n = lineRow(from: r, dir) else { beep(); return }
            r = n
        }
    }

    private func identifierStart(_ i: Int) -> Int { identifier(at: i).map { NSLocationInRange(i, $0) ? $0.location : i } ?? i }

    /// Scrolls by a page and brings the caret along if it went out of view.
    private func page(_ dir: Int) {
        dir > 0 ? scrollPageDown(nil) : scrollPageUp(nil)
        carryCaretIntoView()
    }

    /// Moves the caret and the view down or up by half the view's height, keeping the caret where
    /// it was on screen.
    private func halfPage(_ dir: Int) {
        lineSelectionStart = nil
        guard let clip = enclosingScrollView?.contentView else { return }
        let lines = max(1, Int(visibleRect.height / 2 / style.lineHeight))
        var r = row(at: head) ?? 0
        let before = rect(ofRow: r).minY
        for _ in 0..<lines {
            guard let n = lineRow(from: r, dir) else { break }
            r = n
        }
        let dy = rect(ofRow: r).minY - before
        let target = clip.constrainBoundsRect(NSRect(origin: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + dy), size: clip.bounds.size)).origin
        clip.setBoundsOrigin(target)
        enclosingScrollView?.reflectScrolledClipView(clip)
        setSelectedRange(NSRange(location: landingIndex(ofRow: r), length: 0))
        anchorIndex = selectedRange().location
        headIndex = anchorIndex
    }

    /// Puts the caret on the first line in view if it's out of view.
    private func carryCaretIntoView() {
        guard selectedRange().length == 0, let r = row(at: head), !visibleRect.insetBy(dx: 0, dy: style.lineHeight).intersects(rect(ofRow: r)) else { return }
        var first: Int?
        visibleRows(in: visibleRect.insetBy(dx: 0, dy: style.lineHeight)) { row, _ in if first == nil, rows[row].kind == .line { first = row } }
        guard let first else { return }
        setSelectedRange(NSRange(location: landingIndex(ofRow: first), length: 0))
    }

    /// The fixed end of a selection being extended, and the end that moves.
    private var anchorIndex = 0
    private var headIndex = 0
    /// The column vertical moves aim for, kept while moving up and down through shorter lines.
    private var goalColumn: Int?
    private var movingVertically = false

    private var head: Int {
        let sel = selectedRange()
        if sel == NSRange(location: min(anchorIndex, headIndex), length: abs(headIndex - anchorIndex)) { return headIndex }
        return sel.location
    }

    /// Moves the caret, or the moving end of the selection, and keeps it in view.
    ///
    /// A text view that can't be edited doesn't move its insertion point, so the move commands
    /// below do it here.
    private func moveCaret(to index: Int, extend: Bool) {
        lineSelectionStart = nil
        let i = max(0, min(index, textStorage?.length ?? 0))
        let sel = selectedRange()
        let anchor = extend ? (sel == NSRange(location: min(anchorIndex, headIndex), length: abs(headIndex - anchorIndex)) ? anchorIndex : sel.location) : i
        setSelectedRange(NSRange(location: min(anchor, i), length: abs(i - anchor)))
        anchorIndex = anchor
        headIndex = i
        scrollRangeToVisible(NSRange(location: i, length: 0))
    }

    /// The next row in a direction that holds a line of code.
    private func lineRow(from r: Int, _ dir: Int) -> Int? {
        var n = r + dir
        while rows.indices.contains(n), rows[n].kind != .line { n += dir }
        return rows.indices.contains(n) ? n : nil
    }

    private func moveVertically(_ dir: Int, extend: Bool) {
        let h = head
        guard let r = row(at: h), let n = lineRow(from: r, dir) else { beep(); return }
        let col = goalColumn ?? (h - rowStarts[r])
        let range = charRange(ofRow: n)
        movingVertically = true
        moveCaret(to: range.location + min(col, range.length), extend: extend)
        movingVertically = false
        goalColumn = col
    }

    private func moveHorizontally(_ dir: Int, extend: Bool) {
        let sel = selectedRange()
        if !extend, sel.length > 0 { moveCaret(to: dir < 0 ? sel.location : NSMaxRange(sel), extend: false); return }
        let h = head
        guard let r = row(at: h) else { return }
        let range = charRange(ofRow: r)
        if dir < 0, h == range.location, let p = lineRow(from: r, -1) { moveCaret(to: NSMaxRange(charRange(ofRow: p)), extend: extend); return }
        if dir > 0, h == NSMaxRange(range), let n = lineRow(from: r, 1) { moveCaret(to: rowStarts[n], extend: extend); return }
        moveCaret(to: h + dir, extend: extend)
    }

    private func moveByWord(_ forward: Bool, extend: Bool) {
        guard let s = textStorage, s.length > 0 else { return }
        moveCaret(to: s.nextWord(from: min(head, s.length - 1), forward: forward), extend: extend)
    }

    private func moveToLineEdge(_ end: Bool, extend: Bool) {
        guard let r = row(at: head) else { return }
        let range = charRange(ofRow: r)
        moveCaret(to: end ? NSMaxRange(range) : range.location, extend: extend)
    }

    private func moveToDocumentEdge(_ end: Bool, extend: Bool) {
        guard let r = end ? lineRow(from: rows.count, -1) : lineRow(from: -1, 1) else { return }
        let range = charRange(ofRow: r)
        moveCaret(to: end ? NSMaxRange(range) : range.location, extend: extend)
    }

    override func moveUp(_ sender: Any?) { moveVertically(-1, extend: false) }
    override func moveDown(_ sender: Any?) { moveVertically(1, extend: false) }
    override func moveUpAndModifySelection(_ sender: Any?) { moveVertically(-1, extend: true) }
    override func moveDownAndModifySelection(_ sender: Any?) { moveVertically(1, extend: true) }
    override func moveLeft(_ sender: Any?) { moveHorizontally(-1, extend: false) }
    override func moveRight(_ sender: Any?) { moveHorizontally(1, extend: false) }
    override func moveBackward(_ sender: Any?) { moveHorizontally(-1, extend: false) }
    override func moveForward(_ sender: Any?) { moveHorizontally(1, extend: false) }
    override func moveLeftAndModifySelection(_ sender: Any?) { moveHorizontally(-1, extend: true) }
    override func moveRightAndModifySelection(_ sender: Any?) { moveHorizontally(1, extend: true) }
    override func moveWordLeft(_ sender: Any?) { moveByWord(false, extend: false) }
    override func moveWordRight(_ sender: Any?) { moveByWord(true, extend: false) }
    override func moveWordLeftAndModifySelection(_ sender: Any?) { moveByWord(false, extend: true) }
    override func moveWordRightAndModifySelection(_ sender: Any?) { moveByWord(true, extend: true) }
    override func moveToLeftEndOfLine(_ sender: Any?) { moveToLineEdge(false, extend: false) }
    override func moveToRightEndOfLine(_ sender: Any?) { moveToLineEdge(true, extend: false) }
    override func moveToBeginningOfLine(_ sender: Any?) { moveToLineEdge(false, extend: false) }
    override func moveToEndOfLine(_ sender: Any?) { moveToLineEdge(true, extend: false) }
    override func moveToLeftEndOfLineAndModifySelection(_ sender: Any?) { moveToLineEdge(false, extend: true) }
    override func moveToRightEndOfLineAndModifySelection(_ sender: Any?) { moveToLineEdge(true, extend: true) }
    override func moveToBeginningOfDocument(_ sender: Any?) { moveToDocumentEdge(false, extend: false) }
    override func moveToEndOfDocument(_ sender: Any?) { moveToDocumentEdge(true, extend: false) }
    override func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) { moveToDocumentEdge(false, extend: true) }
    override func moveToEndOfDocumentAndModifySelection(_ sender: Any?) { moveToDocumentEdge(true, extend: true) }

    /// Returns the range of the identifier (letters, digits, `_`, `$`) at or just before a
    /// character index.
    func identifier(at index: Int) -> NSRange? {
        guard let s = textStorage?.string as NSString? else { return nil }
        return SextantCore.identifier(at: index, in: s)
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
        clipsToBounds = true
        clientView = code
        scrollView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrollViewResized), name: NSView.frameDidChangeNotification, object: scrollView)
    }

    @objc private func scrollViewResized() { updateThickness() }

    required init(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Whether changed lines' numbers carry a sign, + for added and − for deleted, so a change
    /// reads without its colour. Only the unified view of a change has the old and new columns
    /// these signs tell apart.
    private var signsNumbers: Bool { columns == 2 }

    /// The width of one column of line numbers, fitting the largest line number and its sign.
    private var numberColumnWidth: CGFloat {
        let maxNo = code.files.reduce(1) { max($0, $1.text.lines.last.map { max($0.oldNo, $0.newNo) } ?? 1) }
        let characters = max(3, String(maxNo).count) + (signsNumbers ? 1 : 0)
        return CGFloat(characters) * code.style.digitWidth + 12
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

    /// Draws the gutter for the rows beside `rect`.
    ///
    /// AppKit keeps what the ruler draws and moves it as the code scrolls, asking only for the parts
    /// it hasn't drawn yet. `rect` can reach beyond the rows in view, such as the whole of a file a
    /// little taller than the view, so it's drawn in full rather than just what's in view.
    ///
    /// The gutter is see-through, so the card's fill behind it shows as it does behind the code;
    /// `GutterScrollView` hides the system's scroll-edge material behind it.
    override func drawHashMarksAndLabels(in rect: NSRect) {
        let s = code.style, t = s.theme
        NSColor.clear.setFill()
        rect.fill(using: .copy)
        t.border.withAlphaComponent(0.5).setFill()
        NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()

        let col = numberColumnWidth
        let blameWidth = blameWidth
        let plainNumbers: [NSAttributedString.Key: Any] = [.font: s.font, .foregroundColor: t.color("lineNumber")]
        let caretNumbers: [NSAttributedString.Key: Any] = [.font: s.boldFont, .foregroundColor: t.fg]
        let caretRow = code.showsCurrentLine ? code.caretRow : nil
        let asked = code.convert(rect, from: self)
        let offset = convert(NSPoint.zero, from: code).y
        var lastBlame: String?
        var isFirstRow = true
        let badgeRow = hoverRow ?? (code.selectedRange().length > 0 ? code.selectedRows.last : nil)

        code.visibleRows(in: NSRect(x: code.bounds.minX, y: asked.minY, width: code.bounds.width, height: asked.height)) { r, frag in
            if isFirstRow {
                lastBlame = blameLabel(continuedAt: r)
                isFirstRow = false
            }
            let numAttrs = r == caretRow ? caretNumbers : plainNumbers
            let y = frag.minY + offset
            let row = code.rows[r]
            guard row.kind == .line, let line = code.line(ofRow: r) else {
                let band = NSRect(x: blameWidth, y: y, width: bounds.width - blameWidth - 1, height: frag.height)
                switch row.kind {
                case .filler:
                    t.color("emptyLine").setFill(); band.fill()
                    t.color("hatch").setStroke(); band.hatch(origin: convert(NSPoint.zero, from: code))
                case .fold, .gap:
                    t.color("hunkNum").setFill(); band.fill()
                default:
                    break
                }
                lastBlame = nil
                return
            }
            let band = NSRect(x: blameWidth, y: y, width: bounds.width - blameWidth - 1, height: frag.height)
            let read = line.kind != .context && code.isReadLine(row.file, row.line)
            if line.kind != .context {
                let changed = line.kind == .added ? t.color("addNum") : t.color("delNum")
                (read ? changed.asRead : changed).setFill()
                band.fill()
            }
            let textY = y + (s.lineHeight - (s.font.ascender - s.font.descender)) / 2
            func number(_ n: Int, column: Int, sign: String = "") {
                guard n > 0 else { return }
                let str = (sign + String(n)) as NSString
                let w = CGFloat(str.length) * s.digitWidth
                str.draw(at: NSPoint(x: blameWidth + col * CGFloat(column + 1) - 8 - w, y: textY), withAttributes: numAttrs)
            }
            if columns == 2 {
                number(line.oldNo, column: 0, sign: line.kind == .deleted ? "\u{2212}" : "")
                number(line.newNo, column: 1, sign: line.kind == .added ? "+" : "")
            } else {
                number(line.kind == .deleted ? line.oldNo : line.newNo, column: 0)
            }
            if line.kind != .context {
                (line.kind == .added ? t.color("success") : t.color("danger")).withAlphaComponent(read ? 0.25 : 0.7).setFill()
                NSRect(x: bounds.maxX - 4, y: y, width: 2, height: frag.height).fill()
            }
            if r == badgeRow { drawAddBadge(at: y) }
            if let blame, line.kind != .deleted, let c = blame.commit(forLine: line.newNo - 1) {
                let label = Self.blameLabel(c)
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

    private static func blameLabel(_ c: Blame.Commit) -> String {
        c.isUncommitted ? "Not committed" : "\(String(c.oid.prefix(7)))  \(c.author)"
    }

    /// The blame label of the run a row continues from the rows above it, or nil if it starts one.
    ///
    /// AppKit asks for the gutter in parts as the code scrolls, so a part that starts mid-run
    /// labels the run only where drawing the whole gutter would.
    private func blameLabel(continuedAt r: Int) -> String? {
        guard let blame else { return nil }
        for above in stride(from: r - 1, through: 0, by: -1) {
            guard let line = code.line(ofRow: above) else { return nil }
            if line.kind != .deleted, let c = blame.commit(forLine: line.newNo - 1) { return Self.blameLabel(c) }
        }
        return nil
    }

    /// The line row under the pointer, which shows the button for adding a note.
    private var hoverRow: Int? { didSet { if hoverRow != oldValue { needsDisplay = true } } }
    private var hoverArea: NSTrackingArea?
    /// The row a drag down the gutter started from.
    private var dragStart: Int?
    private var addingNote = false

    private func badgeRect(at y: CGFloat) -> NSRect {
        let size: CGFloat = 16
        return NSRect(x: blameWidth + 3, y: y + (code.style.lineHeight - size) / 2, width: size, height: size)
    }

    private func drawAddBadge(at y: CGFloat) {
        let box = badgeRect(at: y)
        NSColor.themed("accent").setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        let plus = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Note")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .bold).applying(.init(paletteColors: [.white])))
        plus?.draw(in: box.insetBy(dx: 3, dy: 3))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    private func lineRow(at event: NSEvent) -> (row: Int, y: CGFloat)? {
        let p = convert(event.locationInWindow, from: nil)
        let inCode = code.convert(p, from: self)
        let ci = code.characterIndexForInsertion(at: NSPoint(x: code.textContainerOrigin.x, y: inCode.y))
        guard let r = code.row(at: ci), code.rows[r].kind == .line else { return nil }
        return (r, code.rect(ofRow: r).minY + convert(NSPoint.zero, from: code).y)
    }

    override func mouseMoved(with event: NSEvent) { hoverRow = lineRow(at: event)?.row }
    override func mouseExited(with event: NSEvent) { hoverRow = nil }

    override func mouseDown(with event: NSEvent) {
        guard let (r, y) = lineRow(at: event) else { return }
        let p = convert(event.locationInWindow, from: nil)
        let selected = code.selectedRange().length > 0 ? code.selectedRows : []
        addingNote = badgeRect(at: y).contains(p)
        if addingNote, selected.contains(r), let first = selected.first {
            dragStart = r == first ? selected.last : first
        } else if event.modifierFlags.contains(.shift), let first = selected.first ?? code.caretRow {
            dragStart = first
            code.selectLines(from: first, to: r)
        } else {
            dragStart = r
            code.selectLines(from: r, to: r)
        }
        code.window?.makeFirstResponder(code)
        if !addingNote, p.x < blameWidth, let line = code.line(ofRow: r), line.kind != .deleted,
           let c = blame?.commit(forLine: line.newNo - 1), !c.isUncommitted {
            onBlameClick?(c, line.newNo)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let (r, _) = lineRow(at: event) else { return }
        code.selectLines(from: start, to: r)
        code.autoscroll(with: event)
        hoverRow = nil
    }

    override func mouseUp(with event: NSEvent) {
        defer { addingNote = false; dragStart = nil }
        if addingNote { code.codeDelegate?.codeViewAddNote(code) }
    }

    var onBlameClick: ((Blame.Commit, Int) -> Void)?
}

extension NSColor {
    /// The color at a third of its strength, as a change's colors show once it's been read.
    var asRead: NSColor { withAlphaComponent(alphaComponent / 3) }

    /// The color's sRGB channels, without its alpha.
    var rgb: RGB {
        let c = usingColorSpace(.sRGB) ?? self
        return RGB(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent)
    }

    /// Returns the color laid over an opaque one, at its own alpha.
    func laid(over below: RGB) -> RGB {
        rgb.over(below, alpha: (usingColorSpace(.sRGB) ?? self).alphaComponent)
    }

    convenience init(_ rgb: RGB) {
        self.init(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }
}

extension NSRect {
    /// Strokes diagonal stripes across the rect in the current stroke colour, as on rows that
    /// stand for lines the other side has and this one doesn't.
    ///
    /// - Parameters:
    ///   - origin: Where the stripes' pattern is anchored, in the current view's coordinates.
    ///     Views beside each other that pass the same point continue one pattern.
    ///   - spacing: The distance between stripes along either axis.
    func hatch(origin: NSPoint, spacing: CGFloat = 6) {
        guard !isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: self).addClip()
        let stripes = NSBezierPath()
        stripes.lineWidth = 1
        let first = ((minX - origin.x + minY - origin.y) / spacing).rounded(.down) * spacing
        let last = maxX - origin.x + maxY - origin.y
        for diagonal in stride(from: first, through: last, by: spacing) {
            stripes.move(to: NSPoint(x: origin.x + diagonal - (minY - origin.y), y: minY))
            stripes.line(to: NSPoint(x: origin.x + diagonal - (maxY - origin.y), y: maxY))
        }
        stripes.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A scroll view that places its clip view beside the vertical ruler rather than under it, with
/// the ruler see-through.
///
/// AppKit floats the ruler over the clip view and insets the content instead, so code scrolled
/// sideways passes under the gutter, and it backs the ruler with a hard scroll-edge pocket: the
/// system's material over a live blur of what's behind it. With the code kept clear of the ruler,
/// the pocket has nothing to hide, so the whole pocket is hidden and the gutter shows the card
/// behind it, as the code does. Hiding only its material leaves the blur, which shows as a grey
/// veil over the gutter once the card dims.
@MainActor
final class GutterScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard rulersVisible, let ruler = verticalRulerView else { return }
        for pocket in ruler.subviews where pocket.containsMaterial { pocket.isHidden = true }
        guard contentView.frame.minX < ruler.frame.maxX else { return }
        var frame = contentView.frame
        frame.size.width = max(0, frame.maxX - ruler.frame.maxX)
        frame.origin.x = ruler.frame.maxX
        contentView.frame = frame
        contentView.contentInsets.left = 0
    }
}

private extension NSView {
    /// Whether the view is or holds one of the system's materials.
    var containsMaterial: Bool { self is NSVisualEffectView || subviews.contains { $0.containsMaterial } }
}
