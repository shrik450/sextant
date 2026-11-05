import AppKit
import SextantCore

/// A file in the reader: one of the target's changes, or a file opened while exploring.
@MainActor
final class FileState {
    let diff: FileDiff
    /// Whether the file is one of the target's changes.
    ///
    /// Files opened while exploring are shown as-is, with nothing to review.
    let isChange: Bool
    var reviewed = false
    var conflicted = false
    /// Every line shown for this file.
    ///
    /// Holds just the hunks until the whole file is loaded.
    private(set) var lines: [DiffLine]
    private(set) var isWhole: Bool
    /// The number of unchanged lines left out before the hunk starting at each index into `lines`.
    ///
    /// Only used before the whole file is loaded.
    private(set) var gapsBefore: [Int: Int] = [:]
    /// The folded runs the reader has opened, by their first line index.
    var unfolded: Set<Int> = []
    /// Whether a grammar covers the file, which analysis loads off the main thread.
    let hasLanguage: Bool
    /// Whether the grammar finds definitions, once the file is analyzed.
    private(set) var hasTags: Bool?
    /// The syntax tokens per line, once analyzed.
    private(set) var tokens: [[Token]]?
    /// The new side's definitions, once analyzed with symbols.
    private(set) var definitions: [Symbol]?
    /// The file's definitions with what changed in each, once analyzed with symbols.
    private(set) var outline: [OutlineItem]?
    private var words: [Int: [NSRange]]?
    /// Counts changes to `lines`, so work begun on old lines is dropped.
    private var version = 0
    private var analysis: (task: Task<Void, Never>, symbols: Bool, version: Int)?
    private var wholeLoad: Task<Void, Never>?
    private var preparedWhole: (lines: [DiffLine], analysis: Analysis?)?

    init(diff: FileDiff, isChange: Bool = true) {
        self.diff = diff
        self.isChange = isChange
        hasLanguage = SyntaxRuntime.shared?.hasLanguage(forPath: diff.path) ?? false
        var all: [DiffLine] = []
        var gaps: [Int: Int] = [:]
        for (h, skipped) in zip(diff.hunks, unchangedLinesBefore(diff.hunks)) {
            if skipped > 0 { gaps[all.count] = skipped }
            all += h.lines
        }
        lines = all
        gapsBefore = gaps
        isWhole = diff.hunks.count <= 1 && gaps.isEmpty && (diff.change.isAdded || diff.change.isDeleted || diff.hunks.isEmpty)
    }

    /// Creates a file opened for reading, outside the change being reviewed.
    ///
    /// - Parameter contents: The file's lines, or nil for a binary file.
    convenience init(path: String, contents: [String]?) {
        let change = RawChange(status: "=", oldMode: "100644", newMode: "100644", oldOid: zeroOid, newOid: zeroOid, oldPath: path, path: path)
        self.init(diff: FileDiff(change: change, isBinary: contents == nil), isChange: false)
        setWhole((contents ?? []).enumerated().map { DiffLine(kind: .context, oldNo: $0.offset + 1, newNo: $0.offset + 1, text: $0.element) })
    }

    var path: String { diff.path }

    /// Returns the index of a 1-based line number on one side, or of the nearest line after it.
    func index(ofLine n: Int, old: Bool = false) -> Int? {
        if let exact = lines.firstIndex(where: { old ? $0.kind != .added && $0.oldNo == n : $0.kind != .deleted && $0.newNo == n }) { return exact }
        return lines.firstIndex { old ? $0.oldNo >= n : $0.newNo >= n } ?? (lines.isEmpty ? nil : lines.count - 1)
    }

    /// Returns the 1-based line number of a line index, on the new side unless the line was removed.
    func lineNumber(at i: Int) -> (number: Int, old: Bool) {
        let l = lines[min(max(0, i), lines.count - 1)]
        return l.kind == .deleted ? (l.oldNo, true) : (l.newNo, false)
    }

    /// Returns the reference and code for some line indices.
    ///
    /// The reference uses new-side line numbers, or old-side ones if all the lines were removed.
    func reference(_ indices: [Int]) -> (lines: ClosedRange<Int>, old: Bool, code: [String])? {
        let picked = indices.filter { lines.indices.contains($0) }
        guard !picked.isEmpty else { return nil }
        let old = picked.allSatisfy { lines[$0].kind == .deleted }
        let kept = old ? picked : picked.filter { lines[$0].kind != .deleted }
        let numbers = kept.map { old ? lines[$0].oldNo : lines[$0].newNo }
        guard let lo = numbers.min(), let hi = numbers.max() else { return nil }
        return (lo...hi, old, kept.map { lines[$0].text })
    }
    var hasOldSide: Bool { lines.contains { $0.kind == .deleted } }
    var hasNewSide: Bool { lines.contains { $0.kind == .added } }
    /// Whether both sides have content, so side-by-side shows something on each.
    var isTwoSided: Bool { hasOldSide && hasNewSide }

    static let generatedNames: Set<String> = [
        "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "cargo.lock", "flake.lock", "gemfile.lock",
        "poetry.lock", "composer.lock", "go.sum", "podfile.lock", "pubspec.lock", "mix.lock", "uv.lock",
        "bun.lockb", "package.resolved", "pipfile.lock",
    ]

    var isGenerated: Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        return FileState.generatedNames.contains(name) || name.hasSuffix(".min.js") || name.hasSuffix(".min.css") || name.hasSuffix(".pbxproj")
    }

    func setWhole(_ all: [DiffLine]) {
        lines = all
        isWhole = true
        gapsBefore = [:]
        unfolded = []
        tokens = nil
        definitions = nil
        outline = nil
        words = nil
        runs = nil
        version += 1
        analysis = nil
    }

    /// Whether the whole file is loaded, or ready to adopt.
    var hasWhole: Bool { isWhole || preparedWhole != nil }

    /// Reads the whole file in the background, ready for `adoptWhole()`.
    ///
    /// The file's lines stay as they are until it's adopted, since the reader may be showing
    /// them.
    ///
    /// - Parameter analyzing: Whether to analyze it too, for a file that isn't shown yet. A file
    ///   about to show is analyzed after it shows instead.
    func prepareWhole(git: Git, analyzing: Bool) async {
        guard !hasWhole, !diff.isBinary else { return }
        if let wholeLoad { return await wholeLoad.value }
        let diff = self.diff, isChange = self.isChange
        let task = Task {
            guard let old = try? await git.oldLines(of: diff) else { return }
            preparedWhole = await Task.detached(priority: .userInitiated) {
                let all = wholeFile(diff.hunks, oldLines: old)
                return (all, analyzing ? FileState.analyze(all, path: diff.path, isChange: isChange, symbols: true) : nil)
            }.value
        }
        wholeLoad = task
        await task.value
        wholeLoad = nil
    }

    /// Takes the whole file read elsewhere, ready for `adoptWhole()`.
    func offerWhole(_ all: [DiffLine]) {
        guard !hasWhole else { return }
        preparedWhole = (all, nil)
    }

    /// Shows the whole file prepared or offered, if there is one.
    func adoptWhole() {
        guard let p = preparedWhole else { return }
        preparedWhole = nil
        setWhole(p.lines)
        if let a = p.analysis { apply(a) }
    }

    /// What analyzing a file finds.
    struct Analysis: Sendable {
        var tokens: [[Token]]
        var definitions: [Symbol]?
        var outline: [OutlineItem]?
        var hasTags = false
    }

    /// Analyzes the lines off the main thread, once for each version of them.
    ///
    /// - Parameter symbols: Whether to find definitions and the outline too, which the overview
    ///   doesn't need.
    func analyze(symbols: Bool) async {
        guard hasLanguage else { return }
        if tokens != nil, !symbols || outline != nil { return }
        if let a = analysis, a.version == version, a.symbols || !symbols { return await a.task.value }
        let snapshot = lines, v = version, isChange = self.isChange, path = self.path
        let task = Task {
            let a = await Task.detached(priority: .userInitiated) { FileState.analyze(snapshot, path: path, isChange: isChange, symbols: symbols) }.value
            guard v == version else { return }
            apply(a)
        }
        analysis = (task, symbols, v)
        await task.value
    }

    private func apply(_ a: Analysis) {
        tokens = a.tokens
        if let d = a.definitions { definitions = d }
        if let o = a.outline { outline = o }
        hasTags = a.hasTags
    }

    /// Analyzes each side of some lines as a whole text, so constructs spanning lines come out
    /// right, parsing each side once.
    ///
    /// Loads the file's grammar first, which takes a while the first time, so it runs off the
    /// main thread. A grammar that won't load gives no tokens rather than none at all, so the
    /// file doesn't wait for them.
    nonisolated static func analyze(_ lines: [DiffLine], path: String, isChange: Bool, symbols: Bool) -> Analysis {
        guard let language = SyntaxRuntime.shared?.language(forPath: path) else {
            return Analysis(tokens: [[Token]](repeating: [], count: lines.count), definitions: symbols ? [] : nil, outline: symbols ? [] : nil)
        }
        let wantSymbols = symbols && language.hasTags
        func side(_ old: Bool) -> (indices: [Int], tokens: [[Token]], definitions: [Symbol]) {
            let idx = lines.indices.filter { old ? lines[$0].kind != .added : lines[$0].kind != .deleted }
            let text = idx.map { lines[$0].text }
            let found = language.analyze(text.joined(separator: "\n"), symbols: wantSymbols)
            return (idx, tokensPerLine(found.tokens, lines: text), outlineDefinitions(found.symbols.filter(\.isDefinition)))
        }
        var tokens = [[Token]](repeating: [], count: lines.count)
        let new = side(false)
        for (k, i) in new.indices.enumerated() { tokens[i] = new.tokens[k] }
        var oldDefinitions = new.definitions
        if lines.contains(where: { $0.kind == .deleted }) {
            let old = side(true)
            for (k, i) in old.indices.enumerated() where lines[i].kind == .deleted { tokens[i] = old.tokens[k] }
            if isChange { oldDefinitions = old.definitions }
        }
        guard symbols else { return Analysis(tokens: tokens, hasTags: language.hasTags) }
        return Analysis(tokens: tokens, definitions: new.definitions,
                        outline: wantSymbols ? SextantCore.outline(lines: lines, new: new.definitions, old: oldDefinitions) : [],
                        hasTags: language.hasTags)
    }

    private var runs: [KeyedRun]?

    /// A run of changed lines with the key its read state is kept under.
    struct KeyedRun {
        var run: ChangeRun
        var key: String
    }

    /// The file's runs of changes, with their keys.
    var keyedRuns: [KeyedRun] {
        if let runs { return runs }
        let file = diff.change.reviewKey
        let r = isChange ? changeRuns(lines).map { KeyedRun(run: $0, key: changeKey(file: file, lines: lines[$0.lines])) } : []
        runs = r
        return r
    }

    /// The run of changes holding a line, by index into the file's lines.
    func run(at line: Int) -> KeyedRun? { keyedRuns.first { $0.run.lines.contains(line) } }

    /// Returns the text of one side as it is in the file.
    ///
    /// The old side is the lines with `kind != .added`; the new side is those with
    /// `kind != .deleted`.
    func sideText(old: Bool) -> [String] {
        lines.filter { old ? $0.kind != .added : $0.kind != .deleted }.map(\.text)
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

    /// Returns the unchanged runs to hide when showing just the changes.
    ///
    /// Leaves out runs the reader opened and runs holding a line with a note.
    ///
    /// - Parameter anchored: The indices of lines that have notes.
    func folds(keeping anchored: Set<Int>) -> [Range<Int>] {
        guard isWhole else { return [] }
        return foldedRuns(lines, context: 3).filter { r in
            !unfolded.contains(r.lowerBound) && !anchored.contains { r.contains($0) }
        }
    }

    /// The line index a note is anchored to, if its code is still there.
    func anchor(of note: Note) -> Int? {
        guard let on = note.lines, on.path == path else { return nil }
        let no = on.range.upperBound
        guard let i = lines.firstIndex(where: { on.old ? ($0.kind == .deleted && $0.oldNo == no) : ($0.kind != .deleted && $0.newNo == no) }) else { return nil }
        return on.code.last.map { $0 == lines[i].text } ?? true ? i : nil
    }
}

/// One line of the reader's text.
struct Row: Equatable {
    enum Kind: Equatable {
        /// The file line at `files[file].lines[line]`.
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
func layoutRows(files: [FileState], overview: Bool, split: Bool, showAll: Bool, notes: [Note]) -> Layout {
    var left: [Row] = [], right: [Row] = []
    let sideBySide = split && (overview || files.contains { $0.isTwoSided })
    func both(_ r: Row) { left.append(r); right.append(r) }

    for (fi, f) in files.enumerated() {
        if overview { both(Row(kind: .header, file: fi)) }
        if f.diff.isBinary { both(Row(kind: .notice("Binary file"), file: fi)); continue }
        if f.lines.isEmpty { both(Row(kind: .notice(emptyNotice(f)), file: fi)); continue }

        var anchors: [Int: [Note]] = [:]
        for n in notes { if let a = f.anchor(of: n) { anchors[a, default: []].append(n) } }
        let folds = showAll ? [] : f.folds(keeping: Set(anchors.keys))
        let foldAt = Dictionary(folds.map { ($0.lowerBound, $0) }, uniquingKeysWith: { a, _ in a })
        let twoColumns = sideBySide

        func emitNotes(after i: Int) {
            for n in anchors[i] ?? [] { both(Row(kind: .note(n.id), file: fi, line: i)) }
        }

        var i = 0
        let lines = f.lines
        while i < lines.count {
            if let fold = foldAt[i] {
                both(Row(kind: .fold(fold), file: fi))
                i = fold.upperBound
                continue
            }
            if let hidden = f.gapsBefore[i] { both(Row(kind: .gap(hidden), file: fi, line: i)) }
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
            func continues(_ k: LineKind) -> Bool { i < lines.count && lines[i].kind == k && foldAt[i] == nil && !(i != runStart && f.gapsBefore[i] != nil) }
            while continues(.deleted) { dels.append(i); i += 1 }
            while continues(.added) { adds.append(i); i += 1 }
            for k in 0..<max(dels.count, adds.count) {
                left.append(k < dels.count ? Row(kind: .line, file: fi, line: dels[k]) : Row(kind: .filler, file: fi))
                right.append(k < adds.count ? Row(kind: .line, file: fi, line: adds[k]) : Row(kind: .filler, file: fi))
            }
            for d in dels { emitNotes(after: d) }
            for a in adds { emitNotes(after: a) }
        }
    }
    return Layout(left: left, right: sideBySide ? right : nil)
}

@MainActor
func emptyNotice(_ f: FileState) -> String {
    let d = f.diff
    if d.change.status == "U" { return "Unmerged" }
    if d.change.isRename { return "Renamed without changes" }
    let notes = d.notes.filter { !$0.hasPrefix("old mode") && !$0.hasPrefix("new mode") }
    if !notes.isEmpty { return notes.joined(separator: " · ") }
    if d.change.oldMode != d.change.newMode && d.change.oldMode != "000000" { return "Mode changed from \(d.change.oldMode) to \(d.change.newMode)" }
    if d.change.isAdded { return "Empty file" }
    if d.change.isDeleted { return "Empty file deleted" }
    return f.isChange ? "No content changes" : "Empty file"
}
