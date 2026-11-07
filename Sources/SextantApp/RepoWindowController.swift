import AppKit
import SextantCore

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
    /// How the window looks, which it keeps from when it opens.
    let look: any Look
    /// The frame the columns sit in, which shows what the window reviews.
    let frame: WindowFrame
    let navigator: Navigator
    let strip: PaneStrip
    let inspector: Inspector
    var notes: NotesStore { repository.notes }
    private var watcher: FileWatcher?
    private var watchedPaths: [CanonicalPath] = []

    /// The panes, left to right.
    private(set) var panes: [Pane] = []
    private(set) var focusedPane = 0 { didSet { runWorkWaitingForFile() } }
    /// The pane the keyboard and the side columns follow.
    var pane: Pane { panes[focusedPane] }
    var reader: Reader { pane.reader }

    /// The checkout the window was opened from, which typed revisions like `staged` refer to.
    private(set) var home: CanonicalPath?
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
    /// The search the Find list waits for, which a newer one for the list replaces.
    var findTask: Task<Void, Never>?
    /// The lookup a jump to or peek at a definition waits for, which a newer one replaces.
    var definitionTask: Task<Void, Never>?
    var blameOn = false
    /// The side columns folded away because the window got narrow.
    private var autoCollapsed: Set<SideColumn> = []
    /// The number of loads in flight.
    ///
    /// Automation waits for this to reach zero.
    var busy = 0 { didSet { if busy == 0 { resumeIdleWaiters() } } }
    /// What waits for this window's loads to finish.
    var idleWaiters: [() -> Void] = []
    var lastError: String?
    var picker: NSPopover?
    var sheet: RevisionSheet?
    var jumpPanel: JumpPanel?
    /// The enabled menu commands when the jump bar opened, for it to offer.
    var jumpCommands: [(path: String, item: NSMenuItem)] = []

    init(repository: Repository, home: CanonicalPath?) {
        self.repository = repository
        self.home = home
        look = LookChoice.chosen.look
        frame = look.makeFrame()
        navigator = Navigator(look: look, heading: frame.navigatorHeading)
        strip = PaneStrip(look: look)
        inspector = Inspector(look: look)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 760, height: 420)
        window.title = repository.name
        window.tabbingMode = .automatic
        super.init(window: window)
        window.delegate = self

        navigator.delegate = self
        navigator.changes.reviews = repository.reviews
        inspector.delegate = self
        inspector.notes.delegate = self
        inspector.isRead = { [weak repository] f, r in repository?.reviews.isRead(r.key, in: f.diff.change) ?? false }
        panes = [makePane()]

        frame.install(in: self)
        window.setContentSize(NSSize(width: 1440, height: 900))
        showPanes(animated: false)
        NotificationCenter.default.addObserver(self, selector: #selector(columnsResized(_:)), name: NSSplitView.didResizeSubviewsNotification, object: split.splitView)

        window.autorecalculatesKeyViewLoop = false
        navigator.changes.filter.nextKeyView = navigator.changes.outline
        navigator.search.field.nextKeyView = navigator.search.outline
        navigator.onTabChanged = { [weak self] in self?.updateKeyLoop() }
        updateKeyLoop()
        window.initialFirstResponder = reader.firstKeyView

        placeWindow()

        NotificationCenter.default.addObserver(self, selector: #selector(appearanceChanged(_:)), name: Appearance.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reviewsChanged(_:)), name: ReviewStore.didChange, object: repository.reviews)
        NotificationCenter.default.addObserver(self, selector: #selector(notesChanged(_:)), name: NotesStore.didChange, object: notes)
        watch()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Puts the window where it was last for its repository, which it then keeps up to date, or
    /// else down and to the right of the window opened last, or in the middle of the screen.
    ///
    /// AppKit lets only one open window save its frame under a name, so the name is the
    /// repository's, which has one window.
    private func placeWindow() {
        guard let window else { return }
        let name = "SextantWindow " + repository.commonDir.path
        let restored = window.setFrameUsingName(name)
        let saving = window.setFrameAutosaveName(name)
        guard !(restored && saving) else { return }
        guard let last = (NSApp.delegate as? AppDelegate)?.controllers.last?.window, last !== window else { return window.center() }
        window.setFrame(last.frame, display: false)
        window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
    }

    /// Makes a pane's reader, set up like the others.
    private func makePane() -> Pane {
        let p = Pane(look: look)
        p.loadingChanged = { [weak self] in self?.runWorkWaitingForFile() }
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
        r.header.onToggleZoom = { [weak self, weak p] in
            guard let self, let p, self.focus(p) else { return }
            self.toggleZoomPane(nil)
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
        var paths = [repository.commonDir]
        for s in sessions { if case .worktree(let root) = s.review.subject, !paths.contains(root) { paths.append(root) } }
        guard paths != watchedPaths else { return }
        watchedPaths = paths
        watcher = FileWatcher(paths: paths) { [weak self] changed in MainActor.assumeIsolated { self?.filesystemChanged(changed) } }
    }

    /// Loads the repository's refs, then a review: the one a revision expression names, or all
    /// the work in the checkout it was opened from.
    ///
    /// - Parameter opening: The repository's refs and the review to show, which the app starts
    ///   reading before it makes the window.
    func start(spec: String?, opening: Task<Repository.Opening, Never>) {
        busy += 1
        starting = Task {
            defer { busy -= 1 }
            let o = await opening.value
            await repository.refreshRefs(o.refs)
            updateTitle()
            guard !askedAgain else { return }
            preloaded = o.loaded
            if let spec, !spec.isEmpty {
                await open(spec: spec, in: home)
            } else {
                openWork(in: home)
            }
        }
    }

    /// Reviews what the window's repository is opened for again: a revision expression, or all
    /// the work in a checkout.
    ///
    /// While the window still starts, this waits for the repository's refs, which looking up a
    /// revision needs, and takes the place of what the window was opened with.
    func openAgain(spec: String?, in root: CanonicalPath) async {
        if let starting {
            askedAgain = true
            await starting.value
        }
        if let spec { await open(spec: spec, in: root) } else { openWork(in: root) }
    }

    /// Loading the refs and the first review, until it's done.
    private var starting: Task<Void, Never>?
    /// Whether the window was asked for another review while it started.
    private var askedAgain = false

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
            let conflicts = res.target.includesWorktree ? res.worktree.flatMap { repository.conflicts[$0.root] } ?? [] : []
            for f in s.changes { f.conflicted = conflicts.contains(f.path) }
        }
        guard let res = resolved else { return }
        navigator.changes.setScopes(scopeRows(), selected: res.review.scope)
        navigator.changes.refreshReviewState()
    }

    /// Reviews all the work in a checkout, or offers the picker if there's none to review.
    func openWork(in root: CanonicalPath?) {
        guard let root else { showPicker(nil); return }
        home = root
        let subject = Subject.worktree(root)
        select(Review(subject: subject, base: repository.base(for: subject)), pickerIfEmpty: true)
    }

    /// Reviews what a typed revision expression names.
    func open(spec: String, in root: CanonicalPath?) async {
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
        p.stopLoading()
        p.session = s
        if let current { stopIfUnshown([current]) }
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
        if let base = s.review.base, !repository.branches.contains(where: { $0.name == base }) {
            s.review.base = repository.base(for: s.review.subject)
        }
        let r = s.review
        busy += 1
        s.load { [self] in
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
                    p.reader.showEmpty(error.localizedDescription, symbol: "exclamationmark.triangle")
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
        let sameCommits = keepPosition && key == s.lastKey
        if isFocused(s) { navigator.changes.setScopes(scopeRows(), selected: res.review.scope) }
        let showing = panes(of: s)
        if keepPosition, !showing.contains(where: { $0.pendingLocation != nil }), diffs == s.lastDiffs, key == s.lastKey {
            updateTitle()
            return
        }
        let heres = keepPosition ? Dictionary(showing.compactMap { p in currentLocation(of: p).map { (ObjectIdentifier(p), $0) } }, uniquingKeysWith: { a, _ in a }) : [:]
        let previous = Dictionary(s.changes.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let conflicts = res.target.includesWorktree ? res.worktree.flatMap { repository.conflicts[$0.root] } ?? [] : []
        s.changes = diffs.map { d in
            let f = previous[d.path].flatMap { $0.diff == d ? $0 : nil } ?? FileState(diff: d, contentAnalysis: repository.analysis)
            f.reviewed = repository.reviews.isReviewed(d.change)
            f.conflicted = conflicts.contains(d.path)
            return f
        }
        repository.reviews.prune(res.review, showing: diffs.map(\.change) + res.commits.flatMap(\.changes))
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
        for p in showing {
            let here = heres[ObjectIdentifier(p)]
            if sameCommits, p.pendingLocation == nil, case .file(let path)? = p.focus, let shown = p.reader.files.first?.file, shown.path == path {
                if s.changes.contains(where: { $0 === shown }) {
                    p.reader.updateHeader()
                    continue
                }
                if !shown.isChange, !s.changes.contains(where: { $0.path == path }) {
                    keepIfUnchanged(shown, in: p, here: here)
                    continue
                }
            }
            place(p, here: here)
        }
        s.pickerIfEmpty = false
        updateTitle()
    }

    /// Leaves a pane on a file it opened outside the review while the file reads the same, and
    /// lands it again once it doesn't.
    private func keepIfUnchanged(_ shown: FileState, in p: Pane, here: Location?) {
        guard let s = p.session, let t = s.target else { return }
        let git = s.resolved?.git ?? repository.git
        busy += 1
        s.load { [self] in
            defer { busy -= 1 }
            let data = await git.contents(of: shown.path, in: t.snapshot)
            guard p.session === s, s.target == t, p.reader.files.first?.file === shown, p.pendingLocation == nil else { return }
            if let data, blobID(of: data) == shown.diff.change.newOid {
                s.explored[shown.path] = shown
            } else {
                place(p, here: here)
            }
        }
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
            p.reader.showEmpty(emptyMessage(s), symbol: "checkmark.circle")
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
        s.load { [self] in
            defer { busy -= 1 }
            let listed = try? await git.files(in: snapshot)
            guard !Task.isCancelled, s.target?.snapshot == snapshot else { return }
            let files = (listed ?? []).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
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
        if case .worktree(let root) = res.review.subject {
            guard n > 0 else { return [] }
            rows.append(.everything(title: "All Work", detail: "\(n) commit\(n == 1 ? "" : "s") since \(base), and what isn’t committed"))
            rows.append(.uncommitted(count: repository.uncommitted[root] ?? 0, failure: repository.statusFailures[root]))
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
    var focusedFile: ShownFile? {
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
            p.loadingFile?.cancel()
            p.loadingFile = nil
            p.loadingGeneration = nil
            present(f, at: anchor, in: p)
            prepareNeighbour(of: path, in: s, for: p)
            return
        }
        busy += 1
        p.loadingGeneration = gen
        p.loadingFile?.cancel()
        p.loadingFile = Task {
            defer {
                busy -= 1
                if p.loadingGeneration == gen { p.loadingGeneration = nil }
            }
            let f = await fileState(path, in: t, of: s)
            guard gen == p.showGeneration, !Task.isCancelled else { return }
            guard let f else {
                p.reader.showEmpty("\(path) isn’t in this revision", symbol: "questionmark.text.page")
                if isFocused(p) { inspector.showEmpty(card: card()) }
                return
            }
            present(f, at: anchor, in: p)
            prepareNeighbour(of: path, in: s, for: p)
        }
    }

    /// The file at a path if it can be shown without waiting: once it's read whole, or if it
    /// can't be.
    private func readyFile(_ path: String, in s: Session) -> FileState? {
        guard let f = s.changes.first(where: { $0.path == path }) else { return explored(path, in: s) }
        return f.isReady ? f : nil
    }

    private func fileState(_ path: String, in t: Target, of s: Session) async -> FileState? {
        let git = s.resolved?.git ?? repository.git
        if let f = s.changes.first(where: { $0.path == path }) {
            await f.loadWhole(git: git)
            return f
        }
        if let f = explored(path, in: s) { return f }
        guard let read = await git.read(path, in: t.snapshot) else { return nil }
        let f = switch await Self.admit(read) {
        case .binary(let oid): FileState(path: path, contents: nil, oid: oid, contentAnalysis: repository.analysis)
        case .whole(let lines, let oid): FileState(path: path, contents: lines, oid: oid, contentAnalysis: repository.analysis)
        case .start(let lines, let admission): FileState(path: path, start: lines, admission: admission, contentAnalysis: repository.analysis)
        }
        if s.target == t { s.explored[path] = f }
        return f
    }

    /// What a file opened outside the review shows, as its admission takes it in.
    private enum Explored: Sendable {
        case binary(oid: String)
        case whole(AdmittedLines, oid: String)
        /// The file's first lines, since it's too large to show whole.
        case start(AdmittedLines, Admission)
    }

    /// Decides what of a file read in a snapshot shows, off the main actor.
    @concurrent nonisolated private static func admit(_ read: Git.SnapshotRead) async -> Explored {
        switch read {
        case .whole(let data):
            let oid = blobID(of: data)
            let admission = Admissions.shared.measure(data, oid: oid)
            if admission.isBinary { return .binary(oid: oid) }
            if admission.showsWhole { return .whole(AdmittedLines(data), oid: oid) }
            return .start(AdmittedLines(data, limit: ContentLimits.previewLines), admission)
        case .start(let data, let size):
            let start = Admission(measuring: data)
            return .start(AdmittedLines(data, limit: ContentLimits.previewLines, complete: false),
                          Admission(bytes: size, lines: start.lines, longestLine: start.longestLine, isBinary: start.isBinary))
        }
    }

    /// The most bytes of a neighbour's old side read to prepare it, and of each of its sides
    /// analyzed: a larger one is left until it's opened.
    static let neighbourBytes = 1 << 20

    /// A file read while exploring a review, while its text is still kept or shown.
    private func explored(_ path: String, in s: Session) -> FileState? {
        guard let f = s.explored[path] else { return nil }
        guard f.whole != nil || f.preview != nil || f.diff.isBinary else {
            s.explored[path] = nil
            return nil
        }
        return f
    }

    /// Reads and analyzes the change after a file in the direction the pane reads in, so
    /// stepping to it shows it at once, and stops preparing the one before.
    ///
    /// The pane reads backwards when the file comes before the change it opened last. The
    /// neighbour is read, then analyzed, so a pane opening it waits only for the read. A
    /// neighbour larger than `neighbourBytes` isn't prepared, and stopping a preparation leaves
    /// the read or analysis running for any pane that waits on it.
    private func prepareNeighbour(of path: String, in s: Session, for p: Pane) {
        p.preparingNeighbour?.cancel()
        p.preparingNeighbour = nil
        guard let i = s.changes.firstIndex(where: { $0.path == path }) else { return }
        let backwards = p.lastOpened.map { $0.session == ObjectIdentifier(s) && i < $0.index } ?? false
        p.lastOpened = (ObjectIdentifier(s), i)
        let j = backwards ? i - 1 : i + 1
        guard s.changes.indices.contains(j) else { return }
        let f = s.changes[j]
        let git = s.resolved?.git ?? repository.git
        p.preparingNeighbour = Task {
            guard await f.loadWhole(git: git, limit: Self.neighbourBytes), !Task.isCancelled, let whole = f.whole,
                  whole.admission.bytes <= Self.neighbourBytes else { return }
            await whole.analyze(symbols: true)
        }
    }

    private var afterFrame: [String: Timer] = [:]
    /// Work that came due while the focused pane's file was loading, by key, to run once it shows.
    private var waitingForFile: [String: @MainActor () -> Void] = [:]

    /// Runs work once the run loop has committed what the current event drew, and once however
    /// often it's asked for before then.
    ///
    /// A timer fires after the commit, so the code shows first and the side columns follow.
    /// Work that waits for a loading file waits until the focused pane's file shows, so it
    /// doesn't delay it. The window stays busy from the first ask until the work runs.
    private func afterFrame(_ key: String, waitingForFile waits: Bool = false, _ work: @escaping @MainActor () -> Void) {
        if afterFrame[key] == nil, waitingForFile[key] == nil { busy += 1 }
        afterFrame[key]?.invalidate()
        waitingForFile[key] = nil
        let t = Timer(timeInterval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.afterFrame[key] = nil
                if waits && self.pane.isLoadingFile {
                    self.waitingForFile[key] = work
                    return
                }
                self.busy -= 1
                work()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        afterFrame[key] = t
    }

    /// Runs the work waiting for the focused pane's file after the next frame, once the pane
    /// isn't loading one.
    private func runWorkWaitingForFile() {
        guard !waitingForFile.isEmpty, panes.indices.contains(focusedPane), !pane.isLoadingFile else { return }
        let waiting = waitingForFile
        waitingForFile = [:]
        for (key, work) in waiting { afterFrame(key, waitingForFile: true, work) }
        busy -= waiting.count
    }

    /// Shows a file in the inspector once the reader's frame is on screen.
    private func showInInspector(_ s: ShownFile) {
        afterFrame("inspector") { [weak self] in
            guard let self, self.focusedFile?.text === s.text else { return }
            self.inspector.showFile(s, card: self.card())
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
            if let at = reader.position(of: l) { reader.scroll(to: at, animated: false, select: true) }
        case .restore(let top, let caret):
            if let at = reader.position(of: top) { reader.scroll(to: at, animated: false, offset: 0) }
            if let caret, let at = reader.position(of: caret.line) { reader.placeCaret(at: at, column: caret.column) }
        case .firstChange:
            if f.isChange && reader.hasChanges { reader.scrollToFirstChange() } else { reader.placeCaret(at: ReaderPosition(file: 0, line: 0)) }
        case .lastChange:
            if f.isChange && reader.hasChanges { reader.scrollToLastChange() } else { reader.placeCaret(at: ReaderPosition(file: 0, line: 0)) }
        case .start:
            reader.placeCaret(at: ReaderPosition(file: 0, line: 0))
        }
        guard isFocused(p), let shown = reader.files.first else { return }
        showInInspector(shown)
        if blameOn { loadBlame(f) }
        updateTitle()
    }

    /// Shows every change in a pane, one after another.
    ///
    /// - Parameter p: The pane, or the focused one.
    func showOverview(in p: Pane? = nil, at path: String? = nil, top: SideLine? = nil, caret: Location.Caret? = nil) {
        let p = p ?? pane
        guard let s = p.session, !s.changes.isEmpty else { beep(); return }
        p.stopLoading()
        p.showGeneration += 1
        p.focus = .overview(path: nil)
        UserDefaults.standard.set("overview", forKey: "readerMode")
        let reader = p.reader
        reader.blame = nil
        reader.show(files: s.changes, overview: true)
        if let path, let i = s.changes.firstIndex(where: { $0.path == path }) {
            if let top, let at = reader.position(of: top, inFile: i) {
                reader.scroll(to: at, animated: false, offset: 0)
            } else {
                reader.scrollToFile(i)
            }
        }
        if let caret, let i = s.changes.firstIndex(where: { $0.path == caret.path }), let at = reader.position(of: caret.line, inFile: i) {
            reader.placeCaret(at: at, column: caret.column)
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
            return (reader.files[pos.file].file.path, reader.sideLine(at: pos) ?? SideLine(number: 1, old: false))
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
                p.reader.showEmpty(emptyMessage(s), symbol: "checkmark.circle")
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
        strip.isZoomed = false
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
        guard panes.indices.contains(i) else { beep(); return }
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
        guard panes.count > 1 else { beep(); return }
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
            p.reader.stopWork()
            p.stopLoading()
            p.surface.removeFromSuperview()
        }
        stopIfUnshown(closed.compactMap(\.session))
    }

    /// Stops the work of the sessions no pane shows any more, so a review left behind stops
    /// loading and indexing.
    private func stopIfUnshown(_ left: [Session]) {
        let shown = Set(sessions.map(ObjectIdentifier.init))
        for s in left where !shown.contains(ObjectIdentifier(s)) { s.stopWork() }
    }

    @objc func previousPane(_ sender: Any?) { focusPane(focusedPane - 1) }
    @objc func nextPane(_ sender: Any?) { focusPane(focusedPane + 1) }

    /// Zooms the focused pane to the strip's whole width, or gives every pane its share back.
    ///
    /// The zoom holds while moving between panes, each filling the strip in turn, and ends when a
    /// pane opens beside the focused one or only one is left.
    @objc func toggleZoomPane(_ sender: Any?) {
        guard panes.count > 1 else { beep(); return }
        strip.isZoomed.toggle()
        showPanes(animated: false)
    }

    /// Lays out the strip, sliding the focused pane into view.
    func showPanes(animated: Bool) {
        if panes.count < 2 { strip.isZoomed = false }
        strip.show(panes.map(\.surface), focused: focusedPane, animated: animated)
        for (i, p) in panes.enumerated() {
            p.reader.isFocusedPane = i == focusedPane || panes.count == 1
            p.reader.header.setPane(split: p.reader.split, beside: panes.count > 1, zoomed: strip.isZoomed)
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
        if paths.contains(where: repository.changes.matter) { refresh() }
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

    /// Lays the strip out again when a side column shows, hides or resizes, and lets the frame
    /// follow the columns. The strip can reach under the side columns, so only its safe area and
    /// the titlebar controls over it change, which doesn't lay it out by itself.
    @objc private func columnsResized(_ n: Notification) {
        strip.needsLayout = true
        frame.columnsChanged()
    }

    @objc private func appearanceChanged(_ n: Notification) {
        window?.contentView?.redrawSubtree()
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
        if let review { repository.reviews.set(idx.map { changes[$0] }, reviewed: newValue, in: review) }
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
        for (column, threshold) in [(SideColumn.inspector, 1180.0), (.navigator, 900.0)] {
            let item = split.splitViewItems[column.rawValue]
            if width < threshold, !item.isCollapsed {
                item.isCollapsed = true
                autoCollapsed.insert(column)
            } else if width >= threshold, autoCollapsed.contains(column) {
                autoCollapsed.remove(column)
                if item.isCollapsed { item.isCollapsed = false }
            }
        }
    }

    /// A column beside the panes, by its index among the split items.
    enum SideColumn: Int {
        case navigator = 0
        case inspector = 2
    }

    func isShown(_ column: SideColumn) -> Bool { !split.splitViewItems[column.rawValue].isCollapsed }

    /// Shows or hides a side column, which the window then leaves as the user set it whatever
    /// its width.
    func setShown(_ column: SideColumn, _ shown: Bool, animated: Bool = true) {
        autoCollapsed.remove(column)
        let item = split.splitViewItems[column.rawValue]
        guard item.isCollapsed == shown else { return }
        if animated { item.animator().isCollapsed = !shown } else { item.isCollapsed = !shown }
    }

    @objc func toggleNavigatorColumn(_ sender: Any?) { setShown(.navigator, !isShown(.navigator)) }
    @objc func toggleInspectorColumn(_ sender: Any?) { setShown(.inspector, !isShown(.inspector)) }

    func windowWillClose(_ notification: Notification) {
        watcher = nil
        picker?.close()
        stopWork()
        resumeIdleWaiters()
        (NSApp.delegate as? AppDelegate)?.windowClosed(self)
    }

    /// Lets go of what waits for the window's loads, once they're done or the window closes.
    private func resumeIdleWaiters() {
        let waiting = idleWaiters
        idleWaiters = []
        waiting.forEach { $0() }
    }

    /// Stops what the window started, so none of it runs on, or keeps the window, once it's
    /// closed.
    private func stopWork() {
        refreshTask?.cancel()
        findTask?.cancel()
        definitionTask?.cancel()
        for s in sessions { s.stopWork() }
        for t in afterFrame.values { t.invalidate() }
        afterFrame = [:]
        waitingForFile = [:]
        for p in panes {
            p.reader.stopWork()
            p.stopLoading()
        }
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
        let git = self.git
        findTask?.cancel()
        busy += 1
        findTask = Task {
            defer { busy -= 1 }
            do {
                let m = try await git.grep(query, in: t.snapshot, word: word, ignoreCase: !caseSensitive, maxPerFile: 100)
                guard !Task.isCancelled else { return }
                let limit = 5000
                navigator.search.show(Array(m.prefix(limit)), title: query, capped: m.count > limit)
            } catch {
                guard !Task.isCancelled else { return }
                navigator.search.summary = error.localizedDescription
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
        let anchor: Anchor = line.flatMap { r.sideLine(at: ReaderPosition(file: file, line: $0)) }.map(Anchor.line) ?? .firstChange
        branch()
        open(r.files[file].file.path, at: anchor)
    }

    func readerOpenInEditor(_ r: Reader, file: Int) {
        guard r.files.indices.contains(file) else { return }
        openInEditor(path: r.files[file].file.path, line: 0)
    }

    func readerUnfolded(_ r: Reader) {}

    func readerJumpToDefinition(_ r: Reader, word: String, file: Int, line: Int) {
        readerFocused(r)
        jumpToDefinition(word, from: r.files.indices.contains(file) ? r.files[file].file.path : nil)
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
        guard let f = focusedFile?.file else { return }
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
        guard !list.isEmpty else { beep(); return }
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
