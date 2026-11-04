import AppKit
import RevueCore

/// A 1-based line number on one side of a diff.
struct SideLine: Equatable {
    var number: Int
    var old: Bool
}

/// A place to read: a file or the overview, in a review, with where the view and the caret
/// were.
struct Location: Equatable {
    enum Place: Equatable {
        /// Every change, with `path` as the file at the top.
        case overview(path: String?)
        case file(String)
    }

    struct Caret: Equatable {
        var path: String
        var line: SideLine
        /// The caret's column in the line, as a UTF-16 offset.
        var column: Int?
    }

    var review: Review
    var place: Place
    /// The line at the top of the view.
    var top: SideLine
    var caret: Caret?
}

/// Where the reader lands in a file it opens.
enum Anchor {
    case firstChange, lastChange, start
    /// A line placed comfortably in view, with the caret on it.
    case line(SideLine)
    /// The view and caret put back as they were.
    case restore(top: SideLine, caret: Location.Caret?)
}

/// A repository's window: the navigator, a strip of panes that read the repository, and the
/// inspector.
///
/// Moving through what's read, with the file tree, next and previous file or All Changes,
/// moves the focused pane. Following something from the code, such as a definition, a
/// reference or a blamed commit, opens a pane beside it, so where it came from stays.
@MainActor
final class RepoWindowController: NSWindowController, NSWindowDelegate {
    let repository: Repository
    let split = NSSplitViewController()
    let navigator = Navigator()
    let strip = PaneStrip()
    let inspector = Inspector()
    var notes: NotesStore { repository.notes }
    private var watcher: FileWatcher?
    private var watchedPaths: [String] = []

    /// The panes, left to right.
    private(set) var panes: [Pane] = []
    private(set) var focusedPane = 0
    /// The pane the keyboard and the side columns follow.
    var pane: Pane { panes[focusedPane] }
    var reader: Reader { pane.reader }

    /// The checkout the window was opened from, which typed revisions like `staged` refer to.
    private(set) var home: URL?
    var session: Session? { pane.session }
    var review: Review? { session?.review }
    var resolved: ResolvedReview? { session?.resolved }
    var target: Target? { resolved?.target }
    /// Where the focused review's reads and diffs run.
    var git: Git { resolved?.git ?? repository.git }
    /// The focused review's changes, in diff order.
    var changes: [FileState] { session?.changes ?? [] }
    var commitDetail: CommitDetail? { session?.commitDetail }
    /// What the focused pane shows: the overview of every change, or one file.
    var focus: Location.Place? { pane.focus }
    var searchGeneration = 0
    var blameOn = false
    /// The panes folded away because the window got narrow, by split item index.
    private var autoCollapsed: Set<Int> = []
    /// The number of loads in flight.
    ///
    /// Automation waits for this to reach zero.
    var busy = 0 { didSet { if busy == 0 { RepoWindowController.idleWaiters.forEach { $0() }; RepoWindowController.idleWaiters.removeAll() } } }
    static var idleWaiters: [() -> Void] = []
    var lastError: String?
    var picker: NSPopover?
    weak var subjectControl: SubjectControl?
    var sheet: RevisionSheet?
    var jumpPanel: JumpPanel?
    /// The enabled menu commands when the jump bar opened, for it to offer.
    var jumpCommands: [(path: String, item: NSMenuItem)] = []

    init(repository: Repository, home: URL?) {
        self.repository = repository
        self.home = home
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 760, height: 420)
        window.title = repository.name
        window.tabbingMode = .automatic
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        super.init(window: window)
        window.delegate = self

        navigator.delegate = self
        navigator.changes.reviews = repository.reviews
        inspector.delegate = self
        inspector.notes.delegate = self
        inspector.isRead = { [weak repository] f, r in repository?.reviews.isRead(r.key, in: f.diff.change) ?? false }
        panes = [makePane()]

        let navItem = NSSplitViewItem(sidebarWithViewController: navigator)
        navItem.minimumThickness = 220
        navItem.maximumThickness = 440
        navItem.preferredThicknessFraction = 0.18
        navItem.canCollapse = true
        navItem.canCollapseFromWindowResize = true
        let stripController = NSViewController()
        stripController.view = strip
        let readerItem = NSSplitViewItem(viewController: stripController)
        readerItem.minimumThickness = 420
        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = 220
        inspectorItem.maximumThickness = 420
        inspectorItem.preferredThicknessFraction = 0.18
        inspectorItem.canCollapse = true
        inspectorItem.canCollapseFromWindowResize = true
        split.splitViewItems = [navItem, readerItem, inspectorItem]
        split.splitView.autosaveName = "RevueSplit3"
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1440, height: 900))
        showPanes(animated: false)

        let toolbar = NSToolbar(identifier: "RevueToolbar3")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        window.autorecalculatesKeyViewLoop = false
        navigator.changes.filter.nextKeyView = navigator.changes.outline
        navigator.search.field.nextKeyView = navigator.search.outline
        navigator.onTabChanged = { [weak self] in self?.updateKeyLoop() }
        updateKeyLoop()
        window.initialFirstResponder = reader.firstKeyView

        window.setFrameAutosaveName("RevueWindow")
        if !window.setFrameUsingName("RevueWindow") { window.center() }

        NotificationCenter.default.addObserver(self, selector: #selector(reviewsChanged(_:)), name: ReviewStore.didChange, object: repository.reviews)
        NotificationCenter.default.addObserver(self, selector: #selector(notesChanged(_:)), name: NotesStore.didChange, object: notes)
        watch()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Makes a pane's reader, set up like the others.
    private func makePane() -> Pane {
        let p = Pane()
        let r = p.reader
        r.delegate = self
        r.split = UserDefaults.standard.string(forKey: "diffMode") == "split"
        r.wraps = UserDefaults.standard.bool(forKey: "wrapLines")
        r.isRead = { [weak repository] f, run in repository?.reviews.isRead(run.key, in: f.diff.change) ?? false }
        r.keyLoopNext = inspector.outline
        r.header.onOpenPath = { [weak self, weak p] path in
            guard let self, let p else { return }
            self.open(path, at: .start, in: p)
        }
        r.header.onShowOverview = { [weak self, weak p] in
            guard let self, let p else { return }
            self.showOverview(in: p)
        }
        r.header.onSelectSymbol = { [weak self, weak p] s in
            guard let self, let p, self.focus(p) else { return }
            self.goToDefinition(s)
        }
        r.header.onToggleSplit = { [weak self, weak p] in
            guard let self, let p, self.focus(p) else { return }
            self.setSplit(!self.reader.split)
        }
        r.header.onToggleReviewed = { [weak self, weak p] in
            guard let self, let p, self.focus(p) else { return }
            self.toggleReviewedAction(nil)
        }
        r.header.onClose = { [weak self, weak p] in
            guard let self, let p, self.focus(p) else { return }
            self.closePane(nil)
        }
        _ = r.view
        return p
    }

    /// Focuses a pane for something done from its header, reporting whether it's still open.
    private func focus(_ p: Pane) -> Bool {
        guard let i = panes.firstIndex(where: { $0 === p }) else { return false }
        focusPane(i)
        return true
    }

    private func updateKeyLoop() {
        navigator.focusView.nextKeyView = reader.firstKeyView
        inspector.outline.nextKeyView = navigator.focusView
    }

    /// The panes showing a review.
    private func panes(of s: Session) -> [Pane] { panes.filter { $0.session === s } }

    /// The sessions the panes show, each once.
    private var sessions: [Session] {
        var seen = Set<ObjectIdentifier>()
        return panes.compactMap(\.session).filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    private func isFocused(_ p: Pane) -> Bool { p === pane }
    private func isFocused(_ s: Session) -> Bool { s === session }

    /// Watches the git directory and the checkouts being read.
    private func watch() {
        var paths = [repository.commonDir.path]
        for s in sessions { if case .worktree(let root) = s.review.subject, !paths.contains(root.path) { paths.append(root.path) } }
        guard paths != watchedPaths else { return }
        watchedPaths = paths
        watcher = FileWatcher(paths: paths) { [weak self] changed in self?.filesystemChanged(changed) }
    }

    /// Loads the repository's refs, then a review: the one a revision expression names, or all
    /// the work in the checkout it was opened from.
    ///
    /// - Parameter opening: The repository's refs and the review to show, which the app starts
    ///   reading before it makes the window.
    func start(spec: String?, opening: Task<Repository.Opening, Never>) {
        busy += 1
        Task {
            defer { busy -= 1 }
            let o = await opening.value
            await repository.refreshRefs(o.refs)
            preloaded = o.loaded
            updateTitle()
            if let spec, !spec.isEmpty {
                await open(spec: spec, in: home)
            } else {
                openWork(in: home)
            }
        }
    }

    /// The review read before the window existed, until it's shown.
    private var preloaded: Repository.Loaded?

    private var loadedExtras = false

    /// Loads the worktrees' status and the pull requests once the first review has loaded, since
    /// they only fill in counts and lists and would otherwise compete with it.
    private func loadExtrasOnce() {
        guard !loadedExtras else { return }
        loadedExtras = true
        busy += 1
        Task {
            defer { busy -= 1 }
            if await repository.refreshStatus() { statusChanged() }
        }
        Task { await repository.loadPullRequests() }
    }

    /// Shows the worktrees' status once it arrives after the review it opened with.
    private func statusChanged() {
        updateTitle()
        for s in sessions {
            guard let res = s.resolved else { continue }
            let conflicts = res.target.includesWorktree ? repository.conflicts[res.git.root.path] ?? [] : []
            for f in s.changes { f.conflicted = conflicts.contains(f.path) }
        }
        guard let res = resolved else { return }
        navigator.changes.setScopes(scopeRows(), selected: res.review.scope)
        navigator.changes.refreshReviewState()
    }

    /// Reviews all the work in a checkout, or offers the picker if there's none to review.
    func openWork(in root: URL?) {
        guard let root else { showPicker(nil); return }
        home = root
        let subject = Subject.worktree(root)
        select(Review(subject: subject, base: repository.base(for: subject)), pickerIfEmpty: true)
    }

    /// Reviews what a typed revision expression names.
    func open(spec: String, in root: URL?) async {
        if let root { home = root }
        guard let parsed = parseRevisionSpec(spec) else { openWork(in: root); return }
        do {
            select(try await repository.review(for: parsed, in: root ?? home))
        } catch {
            showError(error)
        }
    }

    /// Shows a review in a pane: another review, or another part of the one it shows.
    ///
    /// Panes showing the same review share what's loaded for it.
    ///
    /// - Parameters:
    ///   - location: Where to land once the review has loaded.
    ///   - p: The pane, or the focused one.
    func select(_ r: Review, then location: Location? = nil, in p: Pane? = nil, pickerIfEmpty: Bool = false) {
        let p = p ?? pane
        let current = p.session
        if let current, current.review == r {
            p.pendingLocation = location
            load(current, keepPosition: true)
            return
        }
        let shared = sessions.first { $0.review == r }
        let s = shared ?? Session(review: r)
        s.pickerIfEmpty = pickerIfEmpty
        p.session = s
        p.pendingLocation = location
        showNotes()
        watch()
        updateTitle()
        if isFocused(p) { bindSideColumns() }
        if shared == nil {
            load(s, keepPosition: false)
        } else if !s.isLoading {
            place(p, here: nil)
        }
    }

    private func load(_ s: Session, keepPosition: Bool) {
        s.loadGeneration += 1
        s.isLoading = true
        let gen = s.loadGeneration
        let r = s.review
        busy += 1
        Task {
            defer {
                busy -= 1
                loadExtrasOnce()
            }
            do {
                let res: ResolvedReview
                let diffs: [FileDiff]
                var firstWhole: [DiffLine]?
                if let pre = preloaded, pre.review == r {
                    res = pre.resolved
                    diffs = pre.diffs
                    firstWhole = pre.firstWhole
                } else {
                    if case .pullRequest = r.subject, repository.pullRequests == nil { await repository.loadPullRequests() }
                    res = try await repository.resolver.resolve(r, worktrees: repository.worktrees, pullRequests: repository.pullRequests ?? [])
                    guard gen == s.loadGeneration else { return }
                    diffs = try await res.git.diff(res.target)
                }
                preloaded = nil
                let paths = diffs.prefix(500).map(\.path)
                Task.detached(priority: .userInitiated) { await SyntaxRuntime.shared?.preload(paths: paths) }
                let detail: CommitDetail? = switch res.target {
                case .commit(let c), .stash(let c): try? await res.git.commitDetail(c)
                default: nil
                }
                guard gen == s.loadGeneration else { return }
                s.isLoading = false
                s.resolved = res
                s.review = res.review
                s.commitDetail = detail
                apply(diffs, to: s, keepPosition: keepPosition, firstWhole: firstWhole)
            } catch {
                guard gen == s.loadGeneration else { return }
                s.isLoading = false
                s.resolved = nil
                s.changes = []
                s.error = error.localizedDescription
                for p in panes(of: s) {
                    p.focus = nil
                    p.reader.showEmpty(error.localizedDescription)
                }
                if isFocused(s) {
                    navigator.changes.setScopes([], selected: .everything)
                    navigator.changes.setFiles([], paths: [])
                    inspector.showEmpty(card: nil)
                }
                lastError = error.localizedDescription
                showPanes(animated: false)
                updateTitle()
            }
        }
    }

    /// Shows a review's changes in the panes that show it.
    ///
    /// - Parameter firstWhole: The first change as a whole file, when it was read already.
    private func apply(_ diffs: [FileDiff], to s: Session, keepPosition: Bool, firstWhole: [DiffLine]? = nil) {
        guard let res = s.resolved else { return }
        let key = "\(res.target)|\(res.commits.map(\.oid))|\(s.commitDetail?.oid ?? "")"
        if isFocused(s) { navigator.changes.setScopes(scopeRows(), selected: res.review.scope) }
        let showing = panes(of: s)
        if keepPosition, !showing.contains(where: { $0.pendingLocation != nil }), diffs == s.lastDiffs, key == s.lastKey {
            updateTitle()
            return
        }
        let heres = keepPosition ? Dictionary(showing.compactMap { p in currentLocation(of: p).map { (ObjectIdentifier(p), $0) } }, uniquingKeysWith: { a, _ in a }) : [:]
        let previous = Dictionary(s.changes.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let conflicts = res.target.includesWorktree ? repository.conflicts[res.git.root.path] ?? [] : []
        s.changes = diffs.map { d in
            let f = previous[d.path].flatMap { $0.diff == d ? $0 : nil } ?? FileState(diff: d)
            f.reviewed = repository.reviews.isReviewed(d.change)
            f.conflicted = conflicts.contains(d.path)
            return f
        }
        if let firstWhole { s.changes.first?.offerWhole(firstWhole) }
        if keepPosition, res.target.snapshot == .worktree {
            s.explored = [:]
            forgetDefinitions(s)
        }
        s.lastDiffs = diffs
        s.lastKey = key
        s.error = nil
        lastError = nil
        loadSnapshotFiles(s, force: keepPosition)
        for p in showing { place(p, here: heres[ObjectIdentifier(p)]) }
        s.pickerIfEmpty = false
        updateTitle()
    }

    /// Lands a pane once its review has loaded: where it was asked to go, where it was, or the
    /// review's first change.
    private func place(_ p: Pane, here: Location?) {
        guard let s = p.session else { return }
        if let loc = p.pendingLocation ?? here {
            p.pendingLocation = nil
            restore(loc, in: p)
        } else if s.changes.isEmpty {
            p.focus = nil
            p.reader.showEmpty(emptyMessage(s))
            if isFocused(p) {
                navigator.changes.showFocus(.none)
                inspector.showEmpty(card: card())
            }
            showPanes(animated: false)
            if s.pickerIfEmpty { showPicker(nil) }
        } else if UserDefaults.standard.string(forKey: "readerMode") == "overview" && s.changes.count > 1 {
            showOverview(in: p)
        } else {
            open(s.changes[0].path, at: .firstChange, in: p)
        }
    }

    /// Lists every file in a review's snapshot, for the file tree and the jump bar.
    private func loadSnapshotFiles(_ s: Session, force: Bool) {
        guard let snapshot = s.target?.snapshot else { return }
        if snapshot != s.snapshotLoaded { s.snapshotFiles = s.changes.filter { !$0.diff.change.isDeleted }.map(\.path) }
        if isFocused(s) { showFilesSoon() }
        guard force || snapshot != s.snapshotLoaded else { return }
        let git = s.resolved?.git ?? repository.git
        busy += 1
        Task {
            defer { busy -= 1 }
            let files = ((try? await git.files(in: snapshot)) ?? []).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            guard s.target?.snapshot == snapshot else { return }
            s.snapshotLoaded = snapshot
            if files != s.snapshotFiles {
                s.snapshotFiles = files
                if isFocused(s) { showFilesSoon() }
            }
            for p in panes(of: s) { p.reader.header.tree = files }
        }
    }

    /// The rows of the commits list: the whole review, its uncommitted work, and its commits.
    func scopeRows() -> [ScopeRow] {
        guard let res = resolved else { return [] }
        let n = res.commits.count
        let base = res.review.base ?? res.mergeBase.map { String($0.prefix(7)) } ?? ""
        var rows: [ScopeRow] = []
        if case .worktree = res.review.subject {
            guard n > 0 else { return [] }
            rows.append(.everything(title: "All Work", detail: "\(n) commit\(n == 1 ? "" : "s") since \(base), and what isn’t committed"))
            rows.append(.uncommitted(count: repository.uncommitted[res.git.root.path] ?? 0))
        } else {
            guard n > 1 else { return [] }
            rows.append(.everything(title: "All \(n) Commits", detail: "Every change since \(base)"))
        }
        return rows + res.commits.map(ScopeRow.commit)
    }

    private func emptyMessage(_ s: Session) -> String {
        switch s.review.scope {
        case .uncommitted: "Nothing uncommitted"
        case .staged: "Nothing staged"
        case .unstaged: "No unstaged changes"
        default: if case .worktree = s.review.subject { "Nothing to review in this checkout" } else { "No changes" }
        }
    }

    /// The file the focused pane shows, when it shows one.
    var focusedFile: FileState? {
        guard case .file? = focus else { return nil }
        return reader.files.first
    }

    /// The change under the focused pane, which is its file or the file at the top of its
    /// overview.
    var currentChange: Int? {
        switch focus {
        case .file(let p)?: return changes.firstIndex { $0.path == p }
        case .overview?: return reader.currentFile
        case nil: return nil
        }
    }

    /// Shows one file in a pane, which is a change or any file in the review's snapshot.
    ///
    /// A file that's ready shows in the same event; otherwise it shows once it's loaded.
    ///
    /// - Parameter p: The pane, or the focused one.
    func open(_ path: String, at anchor: Anchor = .firstChange, in p: Pane? = nil) {
        let p = p ?? pane
        guard let s = p.session, let t = s.target else { return }
        p.focus = .file(path)
        UserDefaults.standard.set("file", forKey: "readerMode")
        p.showGeneration += 1
        let gen = p.showGeneration
        if isFocused(p) { navigator.changes.showFocus(.file(path)) }
        showPanes(animated: false)
        updateTitle()
        if let f = readyFile(path, in: s) {
            p.loadingGeneration = nil
            present(f, at: anchor, in: p)
            prepareNeighbors(of: path, in: s)
            return
        }
        busy += 1
        p.loadingGeneration = gen
        Task {
            defer {
                busy -= 1
                if p.loadingGeneration == gen { p.loadingGeneration = nil }
            }
            let f = await fileState(path, in: t, of: s)
            guard gen == p.showGeneration else { return }
            guard let f else {
                p.reader.showEmpty("\(path) isn’t in this revision")
                if isFocused(p) { inspector.showEmpty(card: card()) }
                return
            }
            present(f, at: anchor, in: p)
            prepareNeighbors(of: path, in: s)
        }
    }

    /// The file at a path if it can be shown without waiting.
    private func readyFile(_ path: String, in s: Session) -> FileState? {
        guard let f = s.changes.first(where: { $0.path == path }) else { return s.explored[path] }
        guard f.hasWhole || f.diff.isBinary else { return nil }
        f.adoptWhole()
        return f
    }

    private func fileState(_ path: String, in t: Target, of s: Session) async -> FileState? {
        let git = s.resolved?.git ?? repository.git
        if let f = s.changes.first(where: { $0.path == path }) {
            await f.prepareWhole(git: git, analyzing: false)
            f.adoptWhole()
            return f
        }
        if let f = s.explored[path] { return f }
        guard let data = await git.contents(of: path, in: t.snapshot) else { return nil }
        let binary = data.prefix(8000).contains(0)
        let f = FileState(path: path, contents: binary ? nil : splitLines(data))
        if s.target == t { s.explored[path] = f }
        return f
    }

    /// Loads and analyzes the changes around a file, so stepping to them shows them at once.
    private func prepareNeighbors(of path: String, in s: Session) {
        guard let i = s.changes.firstIndex(where: { $0.path == path }) else { return }
        let git = s.resolved?.git ?? repository.git
        for j in [i + 1, i - 1, i + 2] where s.changes.indices.contains(j) {
            let f = s.changes[j]
            Task {
                await f.prepareWhole(git: git, analyzing: true)
                if f.isWhole { await f.analyze(symbols: true) }
            }
        }
    }

    private var afterFrame: [String: Timer] = [:]

    /// Runs work once the run loop has committed what the current event drew, and once however
    /// often it's asked for before then.
    ///
    /// A timer fires after the commit, so the code shows first and the side columns follow.
    /// Work that waits for a loading file waits until the focused pane's file shows, so it
    /// doesn't delay it.
    private func afterFrame(_ key: String, waitingForFile: Bool = false, _ work: @escaping @MainActor () -> Void) {
        if afterFrame[key] == nil { busy += 1 }
        afterFrame[key]?.invalidate()
        let t = Timer(timeInterval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if waitingForFile && self.pane.isLoadingFile {
                    self.afterFrame[key] = nil
                    self.busy -= 1
                    self.afterFrame(key, waitingForFile: true, work)
                    return
                }
                self.afterFrame[key] = nil
                self.busy -= 1
                work()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        afterFrame[key] = t
    }

    /// Shows a file in the inspector once the reader's frame is on screen.
    private func showInInspector(_ f: FileState) {
        afterFrame("inspector") { [weak self] in
            guard let self, self.focusedFile === f else { return }
            self.inspector.showFile(f, card: self.card())
            self.inspector.follow(lineIndex: self.reader.caret?.line)
        }
    }

    /// Shows the focused review's files in the navigator, after the code.
    private func showFilesSoon() {
        afterFrame("navigator", waitingForFile: true) { [weak self] in
            guard let self else { return }
            self.navigator.changes.setFiles(self.changes, paths: self.session?.snapshotFiles ?? [])
        }
    }

    private func present(_ f: FileState, at anchor: Anchor, in p: Pane) {
        let reader = p.reader
        reader.blame = nil
        reader.show(files: [f], overview: false)
        switch anchor {
        case .line(let l):
            if let i = f.index(ofLine: l.number, old: l.old) { reader.scroll(to: ReaderPosition(file: 0, line: i), animated: false, select: true) }
        case .restore(let top, let caret):
            if let i = f.index(ofLine: top.number, old: top.old) { reader.scroll(to: ReaderPosition(file: 0, line: i), animated: false, offset: 0) }
            if let caret, let i = f.index(ofLine: caret.line.number, old: caret.line.old) { reader.placeCaret(at: ReaderPosition(file: 0, line: i), column: caret.column) }
        case .firstChange:
            if f.isChange && reader.hasChanges { reader.scrollToFirstChange() } else { reader.placeCaret(at: ReaderPosition(file: 0, line: 0)) }
        case .lastChange:
            if f.isChange && reader.hasChanges { reader.scrollToLastChange() } else { reader.placeCaret(at: ReaderPosition(file: 0, line: 0)) }
        case .start:
            reader.placeCaret(at: ReaderPosition(file: 0, line: 0))
        }
        guard isFocused(p) else { return }
        showInInspector(f)
        if blameOn { loadBlame(f) }
        updateTitle()
    }

    /// Shows every change in a pane, one after another.
    ///
    /// - Parameter p: The pane, or the focused one.
    func showOverview(in p: Pane? = nil, at path: String? = nil, top: SideLine? = nil, caret: Location.Caret? = nil) {
        let p = p ?? pane
        guard let s = p.session, !s.changes.isEmpty else { NSSound.beep(); return }
        p.showGeneration += 1
        p.focus = .overview(path: nil)
        UserDefaults.standard.set("overview", forKey: "readerMode")
        let reader = p.reader
        reader.blame = nil
        reader.show(files: s.changes, overview: true)
        if let path, let i = s.changes.firstIndex(where: { $0.path == path }) {
            if let top, let l = s.changes[i].index(ofLine: top.number, old: top.old) {
                reader.scroll(to: ReaderPosition(file: i, line: l), animated: false, offset: 0)
            } else {
                reader.scrollToFile(i)
            }
        }
        if let caret, let i = s.changes.firstIndex(where: { $0.path == caret.path }), let l = s.changes[i].index(ofLine: caret.line.number, old: caret.line.old) {
            reader.placeCaret(at: ReaderPosition(file: i, line: l), column: caret.column)
        }
        showPanes(animated: false)
        guard isFocused(p) else { return }
        navigator.changes.showFocus(.overview)
        inspector.showOverview(s.changes, card: card())
        inspector.follow(lineIndex: reader.currentFile)
        updateTitle()
    }

    /// Where a pane is, to put it back there.
    func currentLocation(of p: Pane) -> Location? {
        guard let r = p.session?.review, let focus = p.focus else { return nil }
        let reader = p.reader
        func side(_ pos: ReaderPosition?) -> (path: String, line: SideLine)? {
            guard let pos, reader.files.indices.contains(pos.file) else { return nil }
            let f = reader.files[pos.file]
            guard !f.lines.isEmpty else { return (f.path, SideLine(number: 1, old: false)) }
            let (n, old) = f.lineNumber(at: pos.line)
            return (f.path, SideLine(number: n, old: old))
        }
        let top = side(reader.topPosition)
        let caret = side(reader.caret).map { Location.Caret(path: $0.path, line: $0.line, column: reader.caretColumn) }
        switch focus {
        case .overview: return Location(review: r, place: .overview(path: top?.path), top: top?.line ?? SideLine(number: 1, old: false), caret: caret)
        case .file(let path): return Location(review: r, place: .file(path), top: top?.line ?? SideLine(number: 1, old: false), caret: caret)
        }
    }

    /// Where the focused pane is.
    func currentLocation() -> Location? { currentLocation(of: pane) }

    private func restore(_ loc: Location, in p: Pane) {
        guard let s = p.session, loc.review == s.review else {
            select(loc.review, then: loc, in: p)
            return
        }
        switch loc.place {
        case .overview(let path):
            if s.changes.isEmpty {
                p.reader.showEmpty(emptyMessage(s))
                p.focus = nil
            } else {
                showOverview(in: p, at: path, top: loc.top, caret: loc.caret)
            }
        case .file(let path):
            open(path, at: .restore(top: loc.top, caret: loc.caret?.path == path ? loc.caret : nil), in: p)
        }
    }

    // MARK: Panes

    /// Opens a pane to the right of the focused one, on the same review, and focuses it.
    ///
    /// - Parameter takeKeyboard: Whether the new pane's code takes the keyboard, rather than
    ///   leaving it where it is, such as in a list of results.
    @discardableResult
    func branch(takeKeyboard: Bool = true) -> Pane {
        let p = makePane()
        p.session = pane.session
        p.reader.header.tree = pane.session?.snapshotFiles ?? []
        panes.insert(p, at: focusedPane + 1)
        focusedPane += 1
        showNotes()
        showPanes(animated: true)
        p.reader.view.layoutSubtreeIfNeeded()
        if takeKeyboard { reader.focus() }
        paneFocusChanged()
        return p
    }

    /// Focuses a pane, sliding it into view.
    ///
    /// - Parameter takeKeyboard: Whether its code takes the keyboard.
    func focusPane(_ i: Int, takeKeyboard: Bool = true) {
        guard panes.indices.contains(i) else { NSSound.beep(); return }
        let changed = i != focusedPane
        focusedPane = i
        if takeKeyboard { reader.focus() }
        if changed { paneFocusChanged() } else { showPanes(animated: true) }
    }

    /// Closes the focused pane and focuses the one to its left, or closes the window when it's
    /// the only one.
    @objc func closePane(_ sender: Any?) {
        guard panes.count > 1 else { window?.performClose(sender); return }
        let closing = pane
        panes.remove(at: focusedPane)
        focusedPane = max(0, focusedPane - 1)
        discard([closing])
        reader.focus()
        watch()
        paneFocusChanged()
    }

    /// Closes every pane but the focused one.
    @objc func closeOtherPanes(_ sender: Any?) {
        guard panes.count > 1 else { NSSound.beep(); return }
        let kept = pane
        let closing = panes.filter { $0 !== kept }
        panes = [kept]
        focusedPane = 0
        discard(closing)
        watch()
        paneFocusChanged()
    }

    /// Takes closed panes off screen, after they've left the strip, so nothing they do on the
    /// way out reaches the window.
    private func discard(_ closed: [Pane]) {
        for p in closed {
            p.reader.delegate = nil
            p.reader.view.removeFromSuperview()
        }
    }

    @objc func previousPane(_ sender: Any?) { focusPane(focusedPane - 1) }
    @objc func nextPane(_ sender: Any?) { focusPane(focusedPane + 1) }

    /// Lays out the strip, sliding the focused pane into view.
    func showPanes(animated: Bool) {
        strip.show(panes.map(\.reader.view), focused: focusedPane, animated: animated)
        for (i, p) in panes.enumerated() {
            p.reader.header.isFocusedPane = i == focusedPane || panes.count == 1
            p.reader.header.setPane(split: p.reader.split, canClose: panes.count > 1)
        }
    }

    /// Points the navigator, inspector, notes and title at the newly focused pane.
    private func paneFocusChanged() {
        showPanes(animated: true)
        updateKeyLoop()
        bindSideColumns()
        showNotes()
        updateTitle()
    }

    /// Shows the focused pane's review in the navigator, and what it reads in the inspector.
    private func bindSideColumns() {
        guard let s = session, s.resolved != nil else {
            navigator.changes.setScopes([], selected: .everything)
            navigator.changes.setFiles([], paths: [])
            inspector.showEmpty(card: nil)
            return
        }
        navigator.changes.setScopes(scopeRows(), selected: s.review.scope)
        navigator.changes.setFiles(s.changes, paths: s.snapshotFiles)
        switch focus {
        case .file(let path)?:
            navigator.changes.showFocus(.file(path))
            if let f = focusedFile { inspector.showFile(f, card: card()); inspector.follow(lineIndex: reader.caret?.line) }
        case .overview?:
            navigator.changes.showFocus(.overview)
            inspector.showOverview(s.changes, card: card())
            inspector.follow(lineIndex: reader.currentFile)
        case nil:
            navigator.changes.showFocus(.none)
            inspector.showEmpty(card: card())
        }
    }

    private var refreshTask: Task<Void, Never>?

    private func filesystemChanged(_ paths: [String]) {
        let common = repository.commonDir.path
        let relevant = paths.contains { p in
            if p.hasPrefix(common + "/objects") || p.hasPrefix(common + "/revue") || p.hasPrefix(common + "/lfs") || p.hasPrefix(common + "/logs") { return false }
            return !p.hasSuffix(".lock") && !p.contains("/.git/objects/")
        }
        if relevant { refresh() }
    }

    /// Reloads refs and checkouts, then each review shown if anything it shows may have moved.
    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            busy += 1
            defer { busy -= 1 }
            let changed = await repository.refresh()
            for s in sessions where changed || s.target?.includesIndex == true { load(s, keepPosition: true) }
            updateTitle()
        }
    }

    @objc private func reviewsChanged(_ n: Notification) {
        for s in sessions { for f in s.changes { f.reviewed = repository.reviews.isReviewed(f.diff.change) } }
        navigator.changes.refreshReviewState()
        navigator.changes.refreshCommitProgress()
        inspector.refreshReviewState()
        for p in panes {
            p.reader.refreshReadState()
            if case .overview? = p.focus { p.reader.reload(keepPosition: true) } else { p.reader.updateHeader() }
        }
        updateTitle()
    }

    @objc private func notesChanged(_ n: Notification) {
        showNotes()
        for p in panes where !p.reader.files.isEmpty { p.reader.reload(keepPosition: true) }
    }

    /// The notes on what the focused pane reviews.
    var reviewNotes: [Note] { review.map { notes.notes(about: $0.subject) } ?? [] }

    /// Shows each pane's notes on lines beside its code, and the focused review's notes in the
    /// inspector.
    func showNotes() {
        for p in panes { p.reader.notes = p.session.map { notes.notes(about: $0.review.subject).filter { $0.lines != nil } } ?? [] }
        inspector.notes.setNotes(reviewNotes)
    }

    func toggleReviewed(_ paths: [String], advance: Bool) {
        let changes = self.changes
        let idx = changes.indices.filter { paths.contains(changes[$0].path) }
        guard !idx.isEmpty else { return }
        let newValue = !idx.allSatisfy { changes[$0].reviewed }
        for i in idx { changes[i].reviewed = newValue }
        repository.reviews.set(idx.map { changes[$0].diff.change }, reviewed: newValue)
        if newValue, advance, let last = idx.max() {
            let next = changes.indices.first { $0 > last && !changes[$0].reviewed } ?? changes.indices.first { !changes[$0].reviewed }
            if let next {
                if case .overview? = focus { reader.scrollToFile(next) } else { open(changes[next].path) }
            }
        }
        updateTitle()
    }

    func showError(_ error: Error) {
        lastError = error.localizedDescription
        guard let window else { return }
        let a = NSAlert()
        a.messageText = error.localizedDescription
        a.alertStyle = .warning
        a.beginSheetModal(for: window)
    }

    /// Folds the inspector away when the window gets narrow, then the navigator, so the code
    /// keeps its room, and brings back what it folded once there's space again.
    func windowDidResize(_ notification: Notification) {
        guard let width = window?.frame.width else { return }
        for (index, threshold) in [(2, 1180.0), (0, 900.0)] {
            let item = split.splitViewItems[index]
            if width < threshold, !item.isCollapsed {
                item.isCollapsed = true
                autoCollapsed.insert(index)
            } else if width >= threshold, autoCollapsed.contains(index) {
                autoCollapsed.remove(index)
                if item.isCollapsed { item.isCollapsed = false }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        watcher = nil
        picker?.close()
        (NSApp.delegate as? AppDelegate)?.windowClosed(self)
    }
}

extension RepoWindowController: NavigatorDelegate {
    func navigatorSelectScope(_ scope: Scope) {
        guard var r = review, r.scope != scope else { return }
        r.scope = scope
        select(r)
    }

    /// Opens a file from the tree in the focused pane, or beside it when Command is held.
    func navigatorOpen(path: String, line: Int?) {
        let anchor: Anchor = line.map { .line(SideLine(number: $0, old: false)) } ?? .firstChange
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            branch(takeKeyboard: false)
        } else if focus == .file(path) {
            return
        }
        open(path, at: anchor)
    }

    /// Opens a search result beside the code it was searched from, and later results of the
    /// same search in that pane, so stepping through results doesn't move the code behind.
    func navigatorOpenResult(path: String, line: Int) {
        if !pane.showsResults {
            branch(takeKeyboard: false).showsResults = true
        }
        open(path, at: .line(SideLine(number: line, old: false)))
    }

    func navigatorShowOverview() {
        if case .overview? = focus { return }
        showOverview()
    }

    func navigatorToggleReviewed(_ paths: [String]) { toggleReviewed(paths, advance: false) }

    func navigatorFocusReader() { reader.focus() }

    func navigatorSearch(_ query: String, word: Bool, caseSensitive: Bool) {
        guard let t = target else { return }
        searchGeneration += 1
        let gen = searchGeneration
        let git = self.git
        busy += 1
        Task {
            defer { busy -= 1 }
            do {
                let m = try await git.grep(query, in: t.snapshot, word: word, ignoreCase: !caseSensitive, maxPerFile: 100)
                guard gen == searchGeneration else { return }
                let limit = 5000
                navigator.search.show(Array(m.prefix(limit)), title: query, capped: m.count > limit)
            } catch {
                guard gen == searchGeneration else { return }
                navigator.search.status.stringValue = error.localizedDescription
            }
        }
    }
}

extension RepoWindowController: ReaderDelegate {
    /// Focuses the pane whose code took the keyboard.
    func readerFocused(_ r: Reader) {
        guard let i = panes.firstIndex(where: { $0.reader === r }), i != focusedPane else { return }
        focusPane(i, takeKeyboard: false)
    }

    /// Opens a file from the overview beside it.
    func readerOpenFile(_ r: Reader, file: Int, line: Int?) {
        readerFocused(r)
        guard r.files.indices.contains(file) else { return }
        let f = r.files[file]
        let anchor: Anchor
        if let line, !f.lines.isEmpty {
            let (n, old) = f.lineNumber(at: line)
            anchor = .line(SideLine(number: n, old: old))
        } else {
            anchor = .firstChange
        }
        branch()
        open(f.path, at: anchor)
    }

    func readerUnfolded(_ r: Reader) {}

    func readerJumpToDefinition(_ r: Reader, word: String, file: Int, line: Int) {
        readerFocused(r)
        jumpToDefinition(word, from: r.files.indices.contains(file) ? r.files[file].path : nil)
    }

    func readerEditNote(_ r: Reader, id: UUID) { editNote(id) }

    func readerAddNote(_ r: Reader) {
        readerFocused(r)
        addNote(nil)
    }

    func readerPeek(_ r: Reader) {
        readerFocused(r)
        peekDefinition(nil)
    }

    func readerMenu(_ r: Reader, file: Int?, line: Int?) -> NSMenu? {
        readerFocused(r)
        return readerMenu(file: file, line: line)
    }

    func readerCurrentFileChanged(_ r: Reader) {
        guard r === reader else { return }
        updateTitle()
        if case .overview? = focus { inspector.follow(lineIndex: reader.currentFile) }
    }

    func readerCaretMoved(_ r: Reader) {
        guard r === reader else { return }
        if case .file? = focus { inspector.follow(lineIndex: reader.caret?.line) }
        if blameOn { inspector.updateCard(card()) }
    }

    /// Opens the commit that last changed a line beside the code, at that line.
    func readerBlameClicked(_ r: Reader, commit: Blame.Commit, line: Int) {
        readerFocused(r)
        guard let f = focusedFile else { return }
        let review = Review(subject: .commit(commit.oid))
        let at = SideLine(number: line, old: false)
        select(review, then: Location(review: review, place: .file(f.path), top: at, caret: Location.Caret(path: f.path, line: at)), in: branch())
    }
}

extension RepoWindowController: NotesPaneDelegate {
    /// Opens the lines a note is on beside the code.
    func notesPaneOpen(_ note: Note) {
        guard let on = note.lines else { return }
        let anchor = Anchor.line(SideLine(number: on.range.upperBound, old: on.old))
        if focus != .file(on.path) { branch() }
        open(on.path, at: anchor)
    }

    func notesPaneEdit(_ note: Note, relativeTo rect: NSRect, of view: NSView) { editNote(note.id, relativeTo: (rect, view)) }

    func notesPaneDelete(_ ids: Set<UUID>) { notes.remove(ids) }

    func notesPaneCopy(_ selection: [Note]?) {
        let list = selection ?? reviewNotes
        guard !list.isEmpty else { NSSound.beep(); return }
        copy(markdown(list))
    }

    func notesPaneAddOnLines() { addNote(nil) }
    func notesPaneAddOnReview() { addReviewNote(nil) }
}

extension RepoWindowController: InspectorDelegate {
    func inspectorJump(toLineIndex index: Int) { reader.land(onLine: index) }

    func inspectorShowChange(_ index: Int) {
        guard case .overview? = focus else { return }
        reader.scrollToFile(index)
    }
}
