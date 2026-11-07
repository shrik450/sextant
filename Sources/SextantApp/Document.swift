import AppKit
import SextantCore
import Synchronization

/// A file in a review: one of the target's changes, or a file opened while exploring.
///
/// Every pane showing the review shares it, with its review state and its texts. A text never
/// changes once it's made, so a pane keeps line indices into the text it shows however other
/// panes read the file. Which text a pane shows, and which runs it unfolded, are the pane's own
/// (`ShownFile`).
@MainActor
final class FileState {
    let diff: FileDiff
    /// Whether the file is one of the target's changes.
    ///
    /// Files opened while exploring are shown as-is, with nothing to review.
    let isChange: Bool
    var reviewed = false
    var conflicted = false
    /// Whether a grammar covers the file, which analysis loads off the main thread.
    let hasLanguage: Bool
    /// The diff's hunks, with the unchanged lines between them left out.
    ///
    /// When the hunks hold the whole file, as an added file's one hunk does, this is the whole
    /// file too.
    let hunks: FileText
    /// The whole file once it's read: the hunks with the unchanged lines around them filled in.
    ///
    /// The memory cache keeps it while nothing shows it, and drops it when it needs the room;
    /// a pane showing it keeps it, and it goes back in the cache when it's asked for again.
    private(set) var whole: FileText? {
        get {
            if hunks.isWhole { return hunks }
            if let kept = MemoryCache.shared.value(for: wholeKey) as? FileText { return kept }
            guard let shown = wholeShown else { return nil }
            MemoryCache.shared.insert(shown, for: wholeKey, bytes: shown.byteCount)
            return shown
        }
        set {
            wholeShown = newValue
            guard let newValue, newValue !== hunks else { return MemoryCache.shared.remove(wholeKey) }
            newValue.cacheKey = wholeKey
            MemoryCache.shared.insert(newValue, for: wholeKey, bytes: newValue.byteCount)
        }
    }
    /// The whole text while anything holds it, the memory cache or a pane showing it.
    private weak var wholeShown: FileText?
    /// The key the whole text is kept under in the memory cache, unique to this file.
    private let wholeKey = CacheKey(WholeText(id: WholeText.next()))
    private let wholeLoad = SharedWork<WholeRead>()
    /// The largest limit a read of the whole file found its old side larger than.
    private var largerThan = 0
    private let contentAnalysis: ContentAnalysis?

    init(diff: FileDiff, isChange: Bool = true, contentAnalysis: ContentAnalysis?) {
        self.diff = diff
        self.isChange = isChange
        self.contentAnalysis = contentAnalysis
        let hasLanguage = SyntaxRuntime.shared?.hasLanguage(forPath: diff.path) ?? false
        self.hasLanguage = hasLanguage
        var all: [DiffLine] = []
        var gaps: [Int: Int] = [:]
        for (h, skipped) in zip(diff.hunks, unchangedLinesBefore(diff.hunks)) {
            if skipped > 0 { gaps[all.count] = skipped }
            all += h.lines
        }
        let isWhole = diff.hunksAreWholeFile && gaps.isEmpty
        let sidesAreBlobs = (diff.change.isAdded || diff.change.isDeleted) && diff.hunks.count == 1 && diff.notes.isEmpty && diff.omittedLines == 0
        hunks = FileText(all, isWhole: isWhole, gapsBefore: gaps, blobs: sidesAreBlobs ? FileText.blobs(of: diff.change) : (nil, nil),
                         path: diff.path, change: diff.change, isChange: isChange, hasLanguage: hasLanguage, contentAnalysis: contentAnalysis)
    }

    deinit {
        MemoryCache.shared.remove(wholeKey)
    }

    /// Creates a file opened for reading, outside the change being reviewed.
    ///
    /// - Parameters:
    ///   - contents: The file's lines, or nil for a binary file.
    ///   - oid: The blob ID of the file's contents.
    convenience init(path: String, contents: AdmittedLines?, oid: String, contentAnalysis: ContentAnalysis?) {
        let change = RawChange(status: "=", oldMode: "100644", newMode: "100644", oldOid: oid, newOid: oid, oldPath: path, path: path)
        self.init(diff: FileDiff(change: change, isBinary: contents == nil), isChange: false, contentAnalysis: contentAnalysis)
        whole = wholeText(FileState.unchangedLines(contents ?? AdmittedLines(lines: [])))
    }

    /// Creates a file opened for reading, outside the change being reviewed, that's too large to
    /// show whole.
    ///
    /// - Parameters:
    ///   - start: The file's first lines.
    ///   - admission: The admission that found it too large.
    convenience init(path: String, start: AdmittedLines, admission: Admission, contentAnalysis: ContentAnalysis?) {
        let change = RawChange(status: "=", oldMode: "100644", newMode: "100644", oldOid: zeroOid, newOid: zeroOid, oldPath: path, path: path)
        self.init(diff: FileDiff(change: change, isBinary: admission.isBinary), isChange: false, contentAnalysis: contentAnalysis)
        tooLarge = admission
        preview = previewText(start)
    }

    var path: String { diff.path }

    /// The keys of the file's runs of changes, the same in each of its texts.
    var changeKeys: [String] { hunks.keyedRuns.map(\.key) }

    /// The text a pane showing this file by itself shows: the whole file once it's read, else
    /// the start of a file too large to compare, else the hunks.
    var wholeOrHunks: FileText { whole ?? preview ?? hunks }

    /// The admission that found the file too large to show whole, once a read has.
    ///
    /// Such a file shows its hunks, or for a file git didn't compare, its first lines
    /// (`preview`), and the reader says so.
    private(set) var tooLarge: Admission?

    /// The first lines of a file too large to compare, or opened outside the review and too
    /// large to show whole.
    private(set) var preview: FileText?

    /// Whether the file shows as binary: git found it so, or its start shows it is.
    var isBinary: Bool { diff.isBinary || tooLarge?.isBinary == true }

    /// Whether the file can be shown without reading anything more: it's read whole, it's too
    /// large to show whole, or it's binary.
    var isReady: Bool { whole != nil || tooLarge != nil || diff.isBinary }

    nonisolated private static func unchangedLines(_ admitted: AdmittedLines) -> [DiffLine] {
        admitted.lines.enumerated().map { DiffLine(kind: .context, oldNo: $0.offset + 1, newNo: $0.offset + 1, text: $0.element, cut: admitted.cut[$0.offset] ?? 0) }
    }

    private func previewText(_ start: AdmittedLines) -> FileText {
        FileText(FileState.unchangedLines(start), isWhole: false, gapsBefore: [:], blobs: (nil, nil),
                 path: path, change: diff.change, isChange: isChange, hasLanguage: hasLanguage, contentAnalysis: contentAnalysis)
    }

    /// Whether the file has an old side and a new side, so side by side shows something in each
    /// column.
    ///
    /// A modified file has both, even when its change only adds or only removes lines. An added
    /// or deleted file has one, and a file opened outside the change is the same on both.
    var isTwoSided: Bool { isChange && !diff.change.isAdded && !diff.change.isDeleted }

    static let generatedNames: Set<String> = [
        "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "cargo.lock", "flake.lock", "gemfile.lock",
        "poetry.lock", "composer.lock", "go.sum", "podfile.lock", "pubspec.lock", "mix.lock", "uv.lock",
        "bun.lockb", "package.resolved", "pipfile.lock",
    ]

    var isGenerated: Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        return FileState.generatedNames.contains(name) || name.hasSuffix(".min.js") || name.hasSuffix(".min.css") || name.hasSuffix(".pbxproj")
    }

    /// Reads the whole file in the background, once, if it isn't read yet.
    ///
    /// Panes go on showing the text they show; a pane shows the whole file when it next shows
    /// the file. A file that can't be read stays unread, so the next call tries again. Reading
    /// doesn't analyze the file, so a pane waiting to show it waits only for the read. Callers
    /// share one read, which stops once every caller's task is cancelled.
    ///
    /// A file too large to show whole (see `Admission`) isn't read whole: it records
    /// `tooLarge`, and a file git didn't compare reads its first lines as its `preview`.
    ///
    /// - Parameter limit: The most bytes of the old side the caller wants read.
    /// - Returns: Whether the file is ready to show (see `isReady`).
    @discardableResult
    func loadWhole(git: Git, limit: Int = Git.Limit.blob) async -> Bool {
        while !isReady, limit > largerThan {
            let diff = self.diff
            guard let read = await wholeLoad.value(starting: { await FileState.readWhole(diff, git: git, limit: limit) }) else { return false }
            switch read {
            case .lines(let all):
                guard whole == nil else { return true }
                let read = wholeText(all)
                whole = read
                return whole === read
            case .overLimit(let tried): largerThan = max(largerThan, tried)
            case .partial(let admission, let start):
                guard tooLarge == nil else { return true }
                tooLarge = admission
                if let start, !admission.isBinary { preview = previewText(start) }
                return true
            }
        }
        return isReady
    }

    @concurrent nonisolated private static func readWhole(_ diff: FileDiff, git: Git, limit: Int) async -> WholeRead? {
        await git.whole(of: diff, limit: limit)
    }

    /// Takes the whole file read elsewhere, if it isn't read yet.
    func offerWhole(_ all: [DiffLine]) {
        guard whole == nil else { return }
        whole = wholeText(all)
    }

    private func wholeText(_ all: [DiffLine]) -> FileText {
        FileText(all, isWhole: true, gapsBefore: [:], blobs: FileText.blobs(of: diff.change),
                 path: path, change: diff.change, isChange: isChange, hasLanguage: hasLanguage, contentAnalysis: contentAnalysis)
    }
}

/// Names a file's whole text in the memory cache.
private struct WholeText: Hashable, Sendable {
    var id: Int

    private static let last = Mutex(0)

    static func next() -> Int { last.withLock { $0 += 1; return $0 } }
}

/// One of a file's texts: its hunks, or the whole file.
///
/// Its lines never change, so the panes showing it keep line indices into them, and what's
/// worked out from them (syntax tokens, definitions, the outline, names, changed words and runs
/// of changes) is worked out once, for every pane, and stays right.
@MainActor
final class FileText {
    /// Every line, in order. A pane's rows refer to them by index.
    let lines: [DiffLine]
    /// Whether the lines are the whole file, rather than hunks with unchanged lines left out
    /// between them.
    let isWhole: Bool
    /// The number of unchanged lines left out before the hunk starting at each index into
    /// `lines`.
    ///
    /// Empty for a whole file.
    let gapsBefore: [Int: Int]
    let path: String
    /// Whether a grammar covers the file, which analysis loads off the main thread.
    let hasLanguage: Bool
    private let change: RawChange
    private let isChange: Bool
    /// The blob IDs of the sides whose lines are the whole of their blob, so each side's
    /// analysis is shared by its blob's ID.
    private let blobs: (old: String?, new: String?)
    /// Where each version of a file is analyzed once, for every reader.
    private let contentAnalysis: ContentAnalysis?
    /// Whether the grammar finds definitions, once the text is analyzed.
    private(set) var hasTags: Bool?
    /// The syntax tokens per line, once analyzed.
    private(set) var tokens: [[Token]]?
    /// The new side's definitions, once analyzed with symbols.
    private(set) var definitions: [Symbol]?
    /// The file's definitions with what changed in each, once analyzed with symbols.
    private(set) var outline: [OutlineItem]?
    private var words: [Int: [NSRange]]?
    /// Analyzing the text for its tokens alone, and with its definitions and outline.
    private let tokensWork = SharedWork<Analysis>(), symbolsWork = SharedWork<Analysis>()

    fileprivate init(_ lines: [DiffLine], isWhole: Bool, gapsBefore: [Int: Int], blobs: (old: String?, new: String?),
                     path: String, change: RawChange, isChange: Bool, hasLanguage: Bool, contentAnalysis: ContentAnalysis?) {
        self.lines = lines
        self.isWhole = isWhole
        self.gapsBefore = gapsBefore
        self.blobs = blobs
        self.path = path
        self.change = change
        self.isChange = isChange
        self.hasLanguage = hasLanguage
        self.contentAnalysis = contentAnalysis
    }

    /// Where the lines are by their line numbers, and where each stands on the new side.
    private(set) lazy var positions = LinePositions(lines)

    /// The key the text is kept under in the memory cache, if it's kept there.
    var cacheKey: CacheKey?

    /// About how much memory the lines take.
    private lazy var linesByteCount = lines.reduce(0) { $0 + MemoryLayout<DiffLine>.stride + $1.text.utf8.count }

    /// About how much memory the text holds: its lines, and what's worked out from them so far.
    private(set) lazy var byteCount = countBytes()

    private func countBytes() -> Int {
        linesByteCount + (tokens.map(tokensByteCount) ?? 0) + symbolsByteCount(definitions ?? [])
            + (outline?.count ?? 0) * 128 + (names.map { $0.new.index.byteCount + ($0.old?.index.byteCount ?? 0) + lines.count * 8 } ?? 0)
    }

    /// Counts what the text holds again, now that more is worked out from it, and tells the
    /// memory cache.
    private func resized() {
        byteCount = countBytes()
        if let cacheKey { MemoryCache.shared.resize(cacheKey, bytes: byteCount) }
    }

    /// Whether a line is cut to `ContentLimits.lineWidth`, with the rest left out.
    private(set) lazy var hasCutLines = lines.contains { $0.cut > 0 }

    /// What the app takes in of the text, from the larger of its two sides: whether it's
    /// analyzed, and if not, why.
    ///
    /// A side that's the whole of a blob is remembered by the blob's ID (see `Admissions`), so
    /// every other use of that version decides the same.
    private(set) lazy var admission: Admission = {
        var old = (bytes: 0, lines: 0, longest: 0), new = old
        for l in lines {
            let n = l.text.utf8.count
            let width = l.cut > 0 ? l.text.utf16.count + l.cut : n > ContentLimits.analysisLineWidth ? l.text.utf16.count : n
            if l.kind != .added {
                old.bytes += n + l.cut + 1
                old.lines += 1
                old.longest = max(old.longest, width)
            }
            if l.kind != .deleted {
                new.bytes += n + l.cut + 1
                new.lines += 1
                new.longest = max(new.longest, width)
            }
        }
        let oldSide = Admission(bytes: old.bytes, lines: old.lines, longestLine: old.longest)
        let newSide = Admission(bytes: new.bytes, lines: new.lines, longestLine: new.longest)
        if let oid = blobs.old { Admissions.shared.record(oldSide, for: oid) }
        if let oid = blobs.new { Admissions.shared.record(newSide, for: oid) }
        return oldSide.joined(newSide)
    }()

    /// Returns the index of a 1-based line number on one side, or of the nearest line after it.
    func index(ofLine n: Int, old: Bool = false) -> Int? {
        if let exact = positions.index(ofLine: n, old: old) { return exact }
        return lines.firstIndex { old ? $0.oldNo >= n : $0.newNo >= n } ?? (lines.isEmpty ? nil : lines.count - 1)
    }

    /// Returns the line number of a line index, on the new side unless the line was removed.
    ///
    /// - Returns: The number, or nil if the text has no lines.
    func lineNumber(at i: Int) -> SideLine? {
        guard !lines.isEmpty else { return nil }
        let l = lines[min(max(0, i), lines.count - 1)]
        return l.kind == .deleted ? SideLine(number: l.oldNo, old: true) : SideLine(number: l.newNo, old: false)
    }

    /// Returns the reference and code for some line indices (see `referencedLines(_:in:old:)`).
    ///
    /// - Parameter old: The side to name, when the lines were picked in one column of two.
    func reference(_ indices: [Int], old: Bool?) -> (lines: ClosedRange<Int>, old: Bool, code: [String])? {
        referencedLines(indices, in: lines, old: old)
    }

    /// Returns the changed words in a line, if it's one of a pair of removed and added lines.
    func wordRanges(_ line: Int) -> [NSRange] {
        if words == nil {
            var w: [Int: [NSRange]] = [:]
            for (d, a) in pairChangedLines(lines) {
                let dt = lines[d].text, at = lines[a].text
                guard dt.utf16.count < 2000, at.utf16.count < 2000, let r = wordDiff(dt, at) else { continue }
                w[d] = r.old
                w[a] = r.new
            }
            words = w
        }
        return words?[line] ?? []
    }

    private var endings: [Int: String]?

    /// Returns how a removed or added line ends, if it reads the same as its pair but ends
    /// differently, which the reader shows so the change isn't a mystery (see
    /// `changedLineEndings(_:)`).
    func ending(ofLine line: Int) -> String? {
        if endings == nil { endings = changedLineEndings(lines) }
        return endings?[line]
    }

    /// Returns what the reader shows after a line's text: how much of a line too long to take
    /// in whole was left out, and how it ends if that changed.
    func suffix(ofLine line: Int) -> String? {
        let left = lines[line].cut
        let cut = left > 0 ? "… \(left.formatted(.number)) more character\(left == 1 ? "" : "s")" : nil
        switch (cut, ending(ofLine: line)) {
        case let (cut?, ending?): return cut + " · " + ending
        case let (cut, ending): return cut ?? ending
        }
    }

    /// Returns the unchanged runs to hide when showing just the changes.
    ///
    /// Leaves out the runs a pane opened and runs holding a line with a note.
    ///
    /// - Parameters:
    ///   - unfolded: The first line indices of the runs the pane opened.
    ///   - anchored: The indices of lines that have notes.
    func folds(unfolded: Set<Int>, keeping anchored: Set<Int>) -> [Range<Int>] {
        guard isWhole else { return [] }
        return foldedRuns(lines, context: 3).filter { r in
            !unfolded.contains(r.lowerBound) && !anchored.contains { r.contains($0) }
        }
    }

    /// The line index a note is anchored to, if its code is still there.
    func anchor(of note: Note) -> Int? {
        guard let on = note.lines, on.path == path else { return nil }
        let no = on.range.upperBound
        guard let i = positions.index(ofLine: no, old: on.old) else { return nil }
        return on.code.last.map { $0 == lines[i].text } ?? true ? i : nil
    }

    /// What analyzing a text finds.
    struct Analysis: Sendable {
        var tokens: [[Token]]
        var definitions: [Symbol]?
        var outline: [OutlineItem]?
        var hasTags = false
    }

    /// Analyzes the lines off the main thread, once.
    ///
    /// Callers share one analysis, which stops once every caller's task is cancelled.
    ///
    /// - Parameter symbols: Whether to find definitions and the outline too, which the overview
    ///   doesn't need.
    func analyze(symbols: Bool) async {
        guard hasLanguage else { return }
        if tokens != nil, !symbols || outline != nil { return }
        guard admission.analyzes else { return showPlain() }
        let withSymbols = symbols || symbolsWork.isRunning
        let lines = self.lines, isChange = self.isChange, path = self.path, blobs = self.blobs, contentAnalysis = self.contentAnalysis
        let work = withSymbols ? symbolsWork : tokensWork
        guard let a = await work.value(starting: {
            await FileText.analyze(lines, path: path, isChange: isChange, symbols: withSymbols, blobs: blobs, contentAnalysis: contentAnalysis)
        }) else { return }
        tokens = a.tokens
        if let d = a.definitions { definitions = d }
        if let o = a.outline { outline = o }
        hasTags = a.hasTags
        resized()
    }

    /// Gives a text its admission doesn't let be analyzed no tokens, definitions or outline, so
    /// it shows as plain text and nothing waits for it.
    private func showPlain() {
        tokens = [[Token]](repeating: [], count: lines.count)
        definitions = []
        outline = []
        hasTags = false
        resized()
    }

    /// Returns the blob IDs of a change's sides, for the sides that are regular files.
    ///
    /// A symbolic link's lines are its target's path, but in the worktree git hashes the
    /// target's contents instead, so its ID doesn't name its lines.
    nonisolated fileprivate static func blobs(of change: RawChange) -> (old: String?, new: String?) {
        func id(_ oid: String, _ mode: String) -> String? {
            oid != zeroOid && (mode == "100644" || mode == "100755") ? oid : nil
        }
        return (id(change.oldOid, change.oldMode), id(change.newOid, change.newMode))
    }

    /// Analyzes each side of some lines as a whole text, so constructs spanning lines come out
    /// right, parsing each side once.
    ///
    /// A side that is the whole of a blob is analyzed through the content analysis, so each
    /// version of a file is parsed once for every reader. Loads the file's grammar first, which
    /// takes a while the first time, so it runs off the main thread. A grammar that won't load
    /// gives no tokens rather than none at all, so the file doesn't wait for them.
    ///
    /// - Parameter blobs: The blob IDs of the sides whose lines are the whole blob.
    @concurrent nonisolated static func analyze(_ lines: [DiffLine], path: String, isChange: Bool, symbols: Bool,
                                                blobs: (old: String?, new: String?), contentAnalysis: ContentAnalysis?) async -> Analysis {
        guard let language = SyntaxRuntime.shared?.language(forPath: path) else {
            return Analysis(tokens: [[Token]](repeating: [], count: lines.count), definitions: symbols ? [] : nil, outline: symbols ? [] : nil)
        }
        let wantSymbols = symbols && language.hasTags
        @Sendable func side(_ old: Bool) async -> (indices: [Int], tokens: [[Token]], definitions: [Symbol]) {
            let idx = lines.indices.filter { old ? lines[$0].kind != .added : lines[$0].kind != .deleted }
            let text = idx.map { lines[$0].text }
            let found = if let oid = old ? blobs.old : blobs.new, let contentAnalysis {
                await contentAnalysis.analysis(of: text, oid: oid, language: language, definitions: wantSymbols)
            } else {
                language.analysis(of: text, definitions: wantSymbols)
            }
            return (idx, found.tokens, outlineDefinitions(found.definitions ?? []))
        }
        let hasOldSide = lines.contains(where: { $0.kind == .deleted })
        async let newSide = side(false)
        async let oldSide = hasOldSide ? side(true) : nil
        let new = await newSide
        var tokens = [[Token]](repeating: [], count: lines.count)
        for (k, i) in new.indices.enumerated() { tokens[i] = new.tokens[k] }
        var oldDefinitions = new.definitions
        if let old = await oldSide {
            for (k, i) in old.indices.enumerated() where lines[i].kind == .deleted { tokens[i] = old.tokens[k] }
            if isChange { oldDefinitions = old.definitions }
        }
        guard symbols else { return Analysis(tokens: tokens, hasTags: language.hasTags) }
        return Analysis(tokens: tokens, definitions: new.definitions,
                        outline: wantSymbols ? SextantCore.outline(lines: lines, new: new.definitions, old: oldDefinitions) : [],
                        hasTags: language.hasTags)
    }

    /// The names in one side of the text, with where its lines are among the text's.
    struct SideNames: Sendable {
        var index: NameIndex
        /// The index into the text's lines of each of the side's lines.
        var lines: [Int]
        /// The side's line for each of the text's lines, or -1 where the side doesn't have it.
        var sideLines: [Int32]
    }

    /// The names in each side of a text: the new side, and the old side if the text has removed
    /// lines.
    struct Names: Sendable {
        var new: SideNames
        var old: SideNames?
    }

    /// The names in each side of the text, once indexed.
    private var names: Names?
    private let naming = SharedWork<Names>()

    /// Whether the text's names are indexed, so `occurrences(atLine:column:)` can find them.
    var hasNames: Bool { names != nil }

    /// A place a name is used: a line, by index into the text's lines, and its range in the line.
    struct Occurrence: Comparable {
        var line: Int
        var range: NSRange

        static func < (a: Occurrence, b: Occurrence) -> Bool {
            a.line != b.line ? a.line < b.line : a.range.location < b.range.location
        }
    }

    /// Indexes the names in each side of the text off the main thread, once its tokens have
    /// arrived, since they tell names from keywords.
    ///
    /// Callers share one indexing, which stops once every caller's task is cancelled.
    func indexNames() async {
        guard hasLanguage, admission.analyzes, names == nil, let tokens else { return }
        let lines = self.lines, path = self.path
        guard let found = await naming.value(starting: { await FileText.indexNames(lines, tokens: tokens, path: path) }) else { return }
        if names == nil { names = found }
        resized()
    }

    @concurrent nonisolated private static func indexNames(_ lines: [DiffLine], tokens: [[Token]], path: String) async -> Names? {
        guard let language = SyntaxRuntime.shared?.language(forPath: path) else { return nil }
        func side(_ old: Bool) -> SideNames {
            let indices = lines.indices.filter { old ? lines[$0].kind != .added : lines[$0].kind != .deleted }
            var sideLines = [Int32](repeating: -1, count: lines.count)
            for (k, i) in indices.enumerated() { sideLines[i] = Int32(k) }
            let index = language.names(of: indices.map { lines[$0].text }, tokens: indices.map { tokens[$0] })
            return SideNames(index: index, lines: indices, sideLines: sideLines)
        }
        let hasOld = lines.contains { $0.kind == .deleted }
        return Names(new: side(false), old: hasOld ? side(true) : nil)
    }

    /// Returns where the name at a place in the text is used, and the places of the names that
    /// name the same thing, in order.
    ///
    /// A line both sides have finds the name in each. A line only one side has finds it in
    /// that side, then in the other side through a line both have, so a local the change
    /// rewrote is found on its removed and added lines alike. A name with no local scope is
    /// found in the other side by its spelling.
    ///
    /// - Parameters:
    ///   - line: The index into the text's lines.
    ///   - column: The caret's UTF-16 offset in the line.
    /// - Returns: The places, empty if there's no name there, or nil until the names are indexed.
    func occurrences(atLine line: Int, column: Int) -> [Occurrence]? {
        guard let names else { return nil }
        guard lines.indices.contains(line) else { return [] }
        let sides = [names.new] + (names.old.map { [$0] } ?? [])
        var found: [(side: Int, binding: Int)] = []
        var spelling: String?
        for (s, side) in sides.enumerated() where side.sideLines[line] >= 0 {
            guard let n = side.index.name(atLine: Int(side.sideLines[line]), column: column) else { continue }
            found.append((s, n.binding))
            spelling = (lines[line].text as NSString).substring(with: n.range)
        }
        guard let first = found.first, let spelling else { return [] }
        if found.count == 1, sides.count == 2 {
            let from = sides[first.side], other = sides[1 - first.side]
            let across: Int? = if from.index.isLocal(first.binding) {
                from.index.occurrences(of: first.binding).lazy.compactMap { o -> Int? in
                    let l = from.lines[o.line]
                    guard self.lines[l].kind == .context else { return nil }
                    return other.index.name(atLine: Int(other.sideLines[l]), range: o.range)?.binding
                }.first
            } else {
                other.index.binding(spelled: spelling)
            }
            if let across { found.append((1 - first.side, across)) }
        }
        let each = found.map { s, binding in sides[s].index.occurrences(of: binding).map { Occurrence(line: sides[s].lines[$0.line], range: $0.range) } }
        guard each.count == 2 else { return each.first ?? [] }
        let a = each[0], b = each[1]
        var merged: [Occurrence] = []
        merged.reserveCapacity(a.count + b.count)
        var i = 0, j = 0
        while i < a.count || j < b.count {
            let next = j == b.count || (i < a.count && a[i] < b[j]) ? a[i] : b[j]
            if i < a.count, a[i] == next { i += 1 }
            if j < b.count, next == b[j] { j += 1 }
            merged.append(next)
        }
        return merged
    }

    private var runs: [KeyedRun]?

    /// A run of changed lines with the key its read state is kept under.
    ///
    /// The key comes from the run's lines (see `changeKeys(_:runs:)`), so a run has the same
    /// key in the hunks and in the whole file, and reading it in one pane reads it in every pane.
    struct KeyedRun {
        var run: ChangeRun
        var key: String
    }

    /// The text's runs of changes, with their keys.
    var keyedRuns: [KeyedRun] {
        if let runs { return runs }
        let found = isChange ? changeRuns(lines, gapsBefore: gapsBefore) : []
        let r = zip(found, changeKeys(lines, runs: found)).map { KeyedRun(run: $0, key: $1) }
        runs = r
        return r
    }

    /// The run of changes holding a line, by index into the text's lines.
    func run(at line: Int) -> KeyedRun? { keyedRuns.first { $0.run.lines.contains(line) } }
}

/// A file as one pane shows it: which of the file's texts, and the folded runs the pane opened.
///
/// It's the pane's own, so what one pane does with a review's files never changes what another
/// shows.
struct ShownFile {
    let file: FileState
    let text: FileText
    /// The folded runs of unchanged lines the pane opened, by their first line index.
    var unfolded: Set<Int> = []
}

/// One line of the reader's text.
struct Row: Equatable {
    enum Kind: Equatable {
        /// The line at `files[file].text.lines[line]`.
        case line
        /// Space opposite a one-sided change in side-by-side.
        case filler
        /// Hidden unchanged lines of a whole file.
        case fold(Range<Int>)
        /// Unchanged lines between hunks of a file that isn't loaded whole, and how many.
        case gap(Int)
        /// A file's title in the overview.
        case header
        case notice(String)
        /// Says a file shows in part, which opens it in the user's editor when clicked.
        case limit(String)
        case note(UUID)
    }

    var kind: Kind
    var file: Int
    var line = -1
}

/// What the reader lays out, as rows for one text (unified) or two aligned texts (side by side).
struct Layout {
    var left: [Row]
    var right: [Row]?
}

@MainActor
func layoutRows(files: [ShownFile], overview: Bool, split: Bool, showAll: Bool, notes: [Note]) -> Layout {
    var left: [Row] = [], right: [Row] = []
    let sideBySide = split && (overview || files.contains { $0.file.isTwoSided })
    func both(_ r: Row) { left.append(r); right.append(r) }

    for (fi, shown) in files.enumerated() {
        let f = shown.file, t = shown.text
        if overview { both(Row(kind: .header, file: fi)) }
        if f.isBinary { both(Row(kind: .notice("Binary file"), file: fi)); continue }
        let admitted = admissionNotices(f, shown: t)
        for kind in admitted { both(Row(kind: kind, file: fi)) }
        let touchesNoLines = f.isChange && f.diff.hunks.isEmpty && f.diff.uncomparedSize == nil
        if t.lines.isEmpty || (overview && touchesNoLines) {
            if admitted.isEmpty { both(Row(kind: .notice(emptyNotice(f)), file: fi)) }
            continue
        }
        if touchesNoLines { both(Row(kind: .notice(emptyNotice(f)), file: fi)) }

        var anchors: [Int: [Note]] = [:]
        for n in notes { if let a = t.anchor(of: n) { anchors[a, default: []].append(n) } }
        let folds = showAll ? [] : t.folds(unfolded: shown.unfolded, keeping: Set(anchors.keys))
        let foldAt = Dictionary(folds.map { ($0.lowerBound, $0) }, uniquingKeysWith: { a, _ in a })
        let twoColumns = sideBySide

        func emitNotes(after i: Int) {
            for n in anchors[i] ?? [] { both(Row(kind: .note(n.id), file: fi, line: i)) }
        }

        var i = 0
        let lines = t.lines
        while i < lines.count {
            if let fold = foldAt[i] {
                both(Row(kind: .fold(fold), file: fi))
                i = fold.upperBound
                continue
            }
            if let hidden = t.gapsBefore[i] { both(Row(kind: .gap(hidden), file: fi, line: i)) }
            if !twoColumns {
                left.append(Row(kind: .line, file: fi, line: i))
                emitNotes(after: i)
                i += 1
                continue
            }
            if lines[i].kind == .context {
                left.append(Row(kind: .line, file: fi, line: i))
                right.append(Row(kind: .line, file: fi, line: i))
                emitNotes(after: i)
                i += 1
                continue
            }
            var dels: [Int] = [], adds: [Int] = []
            let runStart = i
            func continues(_ k: LineKind) -> Bool { i < lines.count && lines[i].kind == k && foldAt[i] == nil && !(i != runStart && t.gapsBefore[i] != nil) }
            while continues(.deleted) { dels.append(i); i += 1 }
            while continues(.added) { adds.append(i); i += 1 }
            for k in 0..<max(dels.count, adds.count) {
                left.append(k < dels.count ? Row(kind: .line, file: fi, line: dels[k]) : Row(kind: .filler, file: fi))
                right.append(k < adds.count ? Row(kind: .line, file: fi, line: adds[k]) : Row(kind: .filler, file: fi))
                if k < dels.count { emitNotes(after: dels[k]) }
                if k < adds.count { emitNotes(after: adds[k]) }
            }
        }
    }
    return Layout(left: left, right: sideBySide ? right : nil)
}

/// Says why a file shows in part, or as plain text, as the rows heading its lines.
///
/// A file shows in part when it's too large to show whole (see `Admission`): its changes, the
/// first lines of a change too long to take in, or the first lines of a file git didn't
/// compare. Those notices open the file in the user's editor. A file a grammar covers shows as
/// plain text when its text is too large, or its lines too long, to analyze.
@MainActor
func admissionNotices(_ f: FileState, shown t: FileText) -> [Row.Kind] {
    var out: [Row.Kind] = []
    let openIt = "Open in Editor to read it all."
    let first = "These are its first \(t.lines.count.formatted(.number)) lines."
    if let size = f.diff.uncomparedSize {
        let why = Admission(bytes: size, lines: 0, longestLine: 0).reason ?? ""
        out.append(.limit(t === f.preview && !t.lines.isEmpty ? "Too large to compare: \(why). \(first) \(openIt)" : "Too large to compare: \(why). \(openIt)"))
    } else if f.diff.omittedLines > 0, t === f.hunks {
        let total = t.lines.count + f.diff.omittedLines
        out.append(.limit("Only the first \(t.lines.count.formatted(.number)) lines of this change show: it has \(total.formatted(.number)) lines, more than the \(ContentLimits.wholeLines.formatted(.number)) shown whole. \(openIt)"))
    } else if let a = f.tooLarge, !t.isWhole {
        let why = a.reason ?? ""
        out.append(.limit(t === f.preview ? "Too large to show whole: \(why). \(first) \(openIt)" : "Only the changes show: \(why). \(openIt)"))
    }
    if f.hasLanguage, !t.lines.isEmpty, t.admission.verdict == .plain, let why = t.admission.reason {
        let cut = t.hasCutLines ? " Longer lines show their first \(ContentLimits.lineWidth.formatted(.number)) characters." : ""
        out.append(.notice("Plain text, without colours or definitions: \(why).\(cut)"))
    }
    return out
}

/// Says what a change that touches no lines did, such as renaming the file or changing its mode.
///
/// The reader shows it in place of a file with no lines, and above the lines of a file whose
/// change touches none of them.
@MainActor
func emptyNotice(_ f: FileState) -> String {
    let d = f.diff, c = d.change
    if c.status == "U" { return "Unmerged" }
    let modeChanged = c.oldMode != c.newMode && c.oldMode != "000000" && c.newMode != "000000"
    if c.isRename { return modeChanged ? "Renamed, and its mode changed from \(c.oldMode) to \(c.newMode)" : "Renamed without changes" }
    let notes = d.notes.filter { !$0.hasPrefix("old mode") && !$0.hasPrefix("new mode") }
    if !notes.isEmpty { return notes.joined(separator: " · ") }
    if modeChanged { return "Mode changed from \(c.oldMode) to \(c.newMode)" }
    if d.change.isAdded { return "Empty file" }
    if d.change.isDeleted { return "Empty file deleted" }
    return f.isChange ? "No content changes" : "Empty file"
}
