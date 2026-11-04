import AppKit
import RevueCore

/// A 1-based line number on one side of a diff.
struct SideLine: Equatable {
    var number: Int
    var old: Bool
}

/// A place in the history of what was read: a file or the overview, in a review, with where the
/// view and the caret were.
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

/// A repository's window: what's being reviewed, and the navigator, reader and inspector that
/// show it.
@MainActor
final class RepoWindowController: NSWindowController, NSWindowDelegate {
    let repository: Repository
    let split = NSSplitViewController()
    let navigator = Navigator()
    let reader = Reader()
    let inspector = Inspector()
    var notes: NotesStore { repository.notes }
    private var watcher: FileWatcher?
    private var watchedPaths: [String] = []

    /// The checkout the window was opened from, which typed revisions like `staged` refer to.
    private(set) var home: URL?
    private(set) var review: Review?
    private(set) var resolved: ResolvedReview?
    var target: Target? { resolved?.target }
    /// Where the review's reads and diffs run.
    var git: Git { resolved?.git ?? repository.git }
    /// The review's changes, in diff order.
    private(set) var changes: [FileState] = []
    /// Every file in the review's snapshot.
    private(set) var snapshotFiles: [String] = []
    private var snapshotLoaded: Snapshot?
    private(set) var commitDetail: CommitDetail?
    /// Files read while exploring the snapshot, by path.
    private var explored: [String: FileState] = [:]
    /// What the reader shows: the overview of every change, or one file.
    private(set) var focus: Location.Place?
    private var pendingLocation: Location?
    private(set) var backStack: [Location] = []
    private(set) var forwardStack: [Location] = []
    private var loadGeneration = 0
    private var showGeneration = 0
    var searchGeneration = 0
    var blameOn = false
    /// Whether to offer the picker if the review that's loading turns out empty.
    private var pickerIfEmpty = false
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
    weak var reviewItem: NSToolbarItem?
    weak var modeGroup: NSToolbarItemGroup?
    weak var navGroup: NSToolbarItemGroup?
    var sheet: RevisionSheet?

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
        reader.delegate = self
        reader.split = UserDefaults.standard.string(forKey: "diffMode") == "split"
        reader.wraps = UserDefaults.standard.bool(forKey: "wrapLines")
        reader.isRead = { [weak repository] f, r in repository?.reviews.isRead(r.key, in: f.diff.change) ?? false }
        inspector.delegate = self
        inspector.notes.delegate = self
        inspector.isRead = reader.isRead

        let navItem = NSSplitViewItem(sidebarWithViewController: navigator)
        navItem.minimumThickness = 220
        navItem.maximumThickness = 440
        navItem.preferredThicknessFraction = 0.18
        navItem.canCollapse = true
        navItem.canCollapseFromWindowResize = true
        let readerItem = NSSplitViewItem(viewController: reader)
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

        let toolbar = NSToolbar(identifier: "RevueToolbar3")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        window.autorecalculatesKeyViewLoop = false
        navigator.changes.filter.nextKeyView = navigator.changes.outline
        navigator.search.field.nextKeyView = navigator.search.outline
        navigator.onTabChanged = { [weak self] in self?.updateKeyLoop() }
        reader.keyLoopNext = inspector.outline
        updateKeyLoop()
        window.initialFirstResponder = reader.firstKeyView

        reader.jumpBar.onOpenPath = { [weak self] p in self?.open(p, at: .start) }
        reader.jumpBar.onShowOverview = { [weak self] in self?.showOverview() }
        reader.jumpBar.onSelectSymbol = { [weak self] s in self?.goToDefinition(s) }

        window.setFrameAutosaveName("RevueWindow")
        if !window.setFrameUsingName("RevueWindow") { window.center() }

        showNotes()
        NotificationCenter.default.addObserver(self, selector: #selector(reviewsChanged(_:)), name: ReviewStore.didChange, object: repository.reviews)
        NotificationCenter.default.addObserver(self, selector: #selector(notesChanged(_:)), name: NotesStore.didChange, object: notes)
        watch()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateKeyLoop() {
        navigator.focusView.nextKeyView = reader.firstKeyView
        inspector.outline.nextKeyView = navigator.focusView
    }

    /// Watches the git directory and the checkout being reviewed.
    private func watch() {
        var paths = [repository.commonDir.path]
        if case .worktree(let root)? = review?.subject { paths.append(root.path) }
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
        guard let res = resolved else { return }
        navigator.changes.setScopes(scopeRows(), selected: res.review.scope)
        let conflicts = res.target.includesWorktree ? repository.conflicts[res.git.root.path] ?? [] : []
        for f in changes { f.conflicted = conflicts.contains(f.path) }
        navigator.changes.refreshReviewState()
    }

    /// Reviews all the work in a checkout, or offers the picker if there's none to review.
    func openWork(in root: URL?) {
        guard let root else { showPicker(nil); return }
        home = root
        pickerIfEmpty = true
        let subject = Subject.worktree(root)
        select(Review(subject: subject, base: repository.base(for: subject)))
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

    /// Reviews something else, or another part of the same review.
    ///
    /// - Parameter location: Where to land once the review has loaded.
    func select(_ r: Review, then location: Location? = nil, record: Bool = true) {
        let isNew = r != review
        if isNew, record, review != nil { pushHistory() }
        if isNew {
            explored = [:]
            lastDiffs = nil
        }
        review = r
        pendingLocation = location
        if isNew { showNotes() }
        watch()
        updateTitle()
        load(keepPosition: !isNew)
    }

    private var lastDiffs: [FileDiff]?
    private var lastKey: String?

    private func load(keepPosition: Bool) {
        guard let r = review else { return }
        loadGeneration += 1
        let gen = loadGeneration
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
                    guard gen == loadGeneration else { return }
                    diffs = try await res.git.diff(res.target)
                }
                preloaded = nil
                let paths = diffs.prefix(500).map(\.path)
                Task.detached(priority: .userInitiated) { await SyntaxRuntime.shared?.preload(paths: paths) }
                let detail: CommitDetail? = switch res.target {
                case .commit(let c), .stash(let c): try? await res.git.commitDetail(c)
                default: nil
                }
                guard gen == loadGeneration else { return }
                resolved = res
                review = res.review
                commitDetail = detail
                apply(diffs, keepPosition: keepPosition, firstWhole: firstWhole)
            } catch {
                guard gen == loadGeneration else { return }
                resolved = nil
                changes = []
                focus = nil
                navigator.changes.setScopes([], selected: .everything)
                navigator.changes.setFiles([], paths: [])
                reader.showEmpty(error.localizedDescription)
                inspector.showEmpty(card: nil)
                lastError = error.localizedDescription
                updateTitle()
            }
        }
    }

    /// Shows a review's changes.
    ///
    /// - Parameter firstWhole: The first change as a whole file, when it was read already.
    private func apply(_ diffs: [FileDiff], keepPosition: Bool, firstWhole: [DiffLine]? = nil) {
        guard let res = resolved else { return }
        let key = "\(res.target)|\(res.commits.map(\.oid))|\(commitDetail?.oid ?? "")"
        navigator.changes.setScopes(scopeRows(), selected: res.review.scope)
        if keepPosition, pendingLocation == nil, diffs == lastDiffs, key == lastKey {
            updateTitle()
            return
        }
        let here = keepPosition ? currentLocation() : nil
        let previous = Dictionary(changes.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let conflicts = res.target.includesWorktree ? repository.conflicts[res.git.root.path] ?? [] : []
        changes = diffs.map { d in
            let f = previous[d.path].flatMap { $0.diff == d ? $0 : nil } ?? FileState(diff: d)
            f.reviewed = repository.reviews.isReviewed(d.change)
            f.conflicted = conflicts.contains(d.path)
            return f
        }
        if let firstWhole { changes.first?.offerWhole(firstWhole) }
        if keepPosition, res.target.snapshot == .worktree { explored = [:] }
        lastDiffs = diffs
        lastKey = key
        lastError = nil
        loadSnapshotFiles(force: keepPosition)

        if let loc = pendingLocation ?? here {
            pendingLocation = nil
            restore(loc)
        } else if changes.isEmpty {
            focus = nil
            navigator.changes.showFocus(.none)
            reader.showEmpty(emptyMessage)
            inspector.showEmpty(card: card())
            if pickerIfEmpty { showPicker(nil) }
        } else if UserDefaults.standard.string(forKey: "readerMode") == "overview" && changes.count > 1 {
            showOverview(record: false)
        } else {
            open(changes[0].path, at: .firstChange, record: false)
        }
        pickerIfEmpty = false
        updateTitle()
    }

    /// Lists every file in the review's snapshot, for the file tree and the jump bar.
    private func loadSnapshotFiles(force: Bool) {
        guard let snapshot = target?.snapshot else { return }
        if snapshot != snapshotLoaded { snapshotFiles = changes.filter { !$0.diff.change.isDeleted }.map(\.path) }
        showFilesSoon()
        guard force || snapshot != snapshotLoaded else { return }
        let git = self.git
        busy += 1
        Task {
            defer { busy -= 1 }
            let files = ((try? await git.files(in: snapshot)) ?? []).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            guard target?.snapshot == snapshot else { return }
            snapshotLoaded = snapshot
            if files != snapshotFiles {
                snapshotFiles = files
                showFilesSoon()
            }
            reader.jumpBar.tree = files
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

    private var emptyMessage: String {
        switch review?.scope {
        case .uncommitted?: "Nothing uncommitted"
        case .staged?: "Nothing staged"
        case .unstaged?: "No unstaged changes"
        default: if case .worktree? = review?.subject { "Nothing to review in this checkout" } else { "No changes" }
        }
    }

    /// The file the reader shows, when it shows one.
    var focusedFile: FileState? {
        guard case .file? = focus else { return nil }
        return reader.files.first
    }

    /// The change under the reader, which is the focused file or the file at the top of the overview.
    var currentChange: Int? {
        switch focus {
        case .file(let p)?: return changes.firstIndex { $0.path == p }
        case .overview?: return reader.currentFile
        case nil: return nil
        }
    }

    /// Shows one file, which is a change or any file in the review's snapshot.
    ///
    /// A file that's ready shows in the same event; otherwise it shows once it's loaded.
    func open(_ path: String, at anchor: Anchor = .firstChange, record: Bool = true) {
        guard let t = target else { return }
        if record { pushHistory() }
        focus = .file(path)
        UserDefaults.standard.set("file", forKey: "readerMode")
        showGeneration += 1
        let gen = showGeneration
        navigator.changes.showFocus(.file(path))
        updateTitle()
        if let f = readyFile(path) {
            loadingGeneration = nil
            present(f, at: anchor)
            prepareNeighbors(of: path)
            return
        }
        busy += 1
        loadingGeneration = gen
        Task {
            defer {
                busy -= 1
                if loadingGeneration == gen { loadingGeneration = nil }
            }
            let f = await fileState(path, in: t)
            guard gen == showGeneration else { return }
            guard let f else {
                reader.showEmpty("\(path) isn’t in this revision")
                inspector.showEmpty(card: card())
                return
            }
            present(f, at: anchor)
            prepareNeighbors(of: path)
        }
    }

    /// The file at a path if it can be shown without waiting.
    private func readyFile(_ path: String) -> FileState? {
        guard let f = changes.first(where: { $0.path == path }) else { return explored[path] }
        guard f.hasWhole || f.diff.isBinary else { return nil }
        f.adoptWhole()
        return f
    }

    private func fileState(_ path: String, in t: Target) async -> FileState? {
        let git = self.git
        if let f = changes.first(where: { $0.path == path }) {
            await f.prepareWhole(git: git, analyzing: false)
            f.adoptWhole()
            return f
        }
        if let f = explored[path] { return f }
        guard let data = await git.contents(of: path, in: t.snapshot) else { return nil }
        let binary = data.prefix(8000).contains(0)
        let f = FileState(path: path, contents: binary ? nil : splitLines(data))
        if target == t { explored[path] = f }
        return f
    }

    /// Loads and analyzes the changes around a file, so stepping to them shows them at once.
    private func prepareNeighbors(of path: String) {
        guard let i = changes.firstIndex(where: { $0.path == path }) else { return }
        let git = self.git
        for j in [i + 1, i - 1, i + 2] where changes.indices.contains(j) {
            let f = changes[j]
            Task {
                await f.prepareWhole(git: git, analyzing: true)
                if f.isWhole { await f.analyze(symbols: true) }
            }
        }
    }

    private var afterFrame: [String: Timer] = [:]
    /// Whether a file is loading to show, which the side panes wait for.
    private var loadingFile: Bool { loadingGeneration == showGeneration }
    private var loadingGeneration: Int?

    /// Runs work once the run loop has committed what the current event drew, and once however
    /// often it's asked for before then.
    ///
    /// A timer fires after the commit, so the code shows first and the side panes follow. Work
    /// that waits for a loading file waits until the file shows, so it doesn't delay it.
    private func afterFrame(_ key: String, waitingForFile: Bool = false, _ work: @escaping @MainActor () -> Void) {
        if afterFrame[key] == nil { busy += 1 }
        afterFrame[key]?.invalidate()
        let t = Timer(timeInterval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if waitingForFile && self.loadingFile {
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

    /// Shows the review's files in the navigator, after the code.
    private func showFilesSoon() {
        afterFrame("navigator", waitingForFile: true) { [weak self] in
            guard let self else { return }
            self.navigator.changes.setFiles(self.changes, paths: self.snapshotFiles)
        }
    }

    private func present(_ f: FileState, at anchor: Anchor) {
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
        showInInspector(f)
        if blameOn { loadBlame(f) }
        updateNavButtons()
        updateTitle()
    }

    func showOverview(record: Bool = true, at path: String? = nil, top: SideLine? = nil, caret: Location.Caret? = nil) {
        guard !changes.isEmpty else { NSSound.beep(); return }
        if record { pushHistory() }
        showGeneration += 1
        focus = .overview(path: nil)
        UserDefaults.standard.set("overview", forKey: "readerMode")
        reader.blame = nil
        reader.show(files: changes, overview: true)
        if let path, let i = changes.firstIndex(where: { $0.path == path }) {
            if let top, let l = changes[i].index(ofLine: top.number, old: top.old) {
                reader.scroll(to: ReaderPosition(file: i, line: l), animated: false, offset: 0)
            } else {
                reader.scrollToFile(i)
            }
        }
        if let caret, let i = changes.firstIndex(where: { $0.path == caret.path }), let l = changes[i].index(ofLine: caret.line.number, old: caret.line.old) {
            reader.placeCaret(at: ReaderPosition(file: i, line: l), column: caret.column)
        }
        navigator.changes.showFocus(.overview)
        inspector.showOverview(changes, card: card())
        inspector.follow(lineIndex: reader.currentFile)
        updateNavButtons()
        updateTitle()
    }

    func currentLocation() -> Location? {
        guard let r = review, let focus else { return nil }
        func side(_ p: ReaderPosition?) -> (path: String, line: SideLine)? {
            guard let p, reader.files.indices.contains(p.file) else { return nil }
            let f = reader.files[p.file]
            guard !f.lines.isEmpty else { return (f.path, SideLine(number: 1, old: false)) }
            let (n, old) = f.lineNumber(at: p.line)
            return (f.path, SideLine(number: n, old: old))
        }
        let top = side(reader.topPosition)
        let caret = side(reader.caret).map { Location.Caret(path: $0.path, line: $0.line, column: reader.caretColumn) }
        switch focus {
        case .overview: return Location(review: r, place: .overview(path: top?.path), top: top?.line ?? SideLine(number: 1, old: false), caret: caret)
        case .file(let p): return Location(review: r, place: .file(p), top: top?.line ?? SideLine(number: 1, old: false), caret: caret)
        }
    }

    func pushHistory() {
        guard let here = currentLocation() else { return }
        if backStack.last != here { backStack.append(here) }
        if backStack.count > 200 { backStack.removeFirst() }
        forwardStack.removeAll()
        updateNavButtons()
    }

    private func restore(_ loc: Location) {
        if loc.review != review {
            select(loc.review, then: loc, record: false)
            return
        }
        switch loc.place {
        case .overview(let path):
            if changes.isEmpty {
                reader.showEmpty(emptyMessage)
                focus = nil
            } else {
                showOverview(record: false, at: path, top: loc.top, caret: loc.caret)
            }
        case .file(let p):
            open(p, at: .restore(top: loc.top, caret: loc.caret?.path == p ? loc.caret : nil), record: false)
        }
    }

    @objc func goBack(_ sender: Any?) {
        guard let loc = backStack.popLast() else { NSSound.beep(); return }
        if let here = currentLocation() { forwardStack.append(here) }
        restore(loc)
        updateNavButtons()
    }

    @objc func goForward(_ sender: Any?) {
        guard let loc = forwardStack.popLast() else { NSSound.beep(); return }
        if let here = currentLocation() { backStack.append(here) }
        restore(loc)
        updateNavButtons()
    }

    func updateNavButtons() {
        navGroup?.subitems[0].isEnabled = !backStack.isEmpty
        navGroup?.subitems[1].isEnabled = !forwardStack.isEmpty
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

    /// Reloads refs and checkouts, then the review if anything it shows may have moved.
    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            busy += 1
            defer { busy -= 1 }
            let changed = await repository.refresh()
            if changed || target?.includesIndex == true { load(keepPosition: true) }
            updateTitle()
        }
    }

    @objc private func reviewsChanged(_ n: Notification) {
        for f in changes { f.reviewed = repository.reviews.isReviewed(f.diff.change) }
        navigator.changes.refreshReviewState()
        navigator.changes.refreshCommitProgress()
        inspector.refreshReviewState()
        reader.refreshReadState()
        if case .overview? = focus { reader.reload(keepPosition: true) }
        updateTitle()
    }

    @objc private func notesChanged(_ n: Notification) {
        showNotes()
        if !reader.files.isEmpty { reader.reload(keepPosition: true) }
    }

    /// The notes on what's being reviewed.
    var reviewNotes: [Note] { review.map { notes.notes(about: $0.subject) } ?? [] }

    /// Shows the review's notes in the inspector, and its notes on lines beside them in the reader.
    func showNotes() {
        let n = reviewNotes
        reader.notes = n.filter { $0.lines != nil }
        inspector.notes.setNotes(n)
    }

    func toggleReviewed(_ paths: [String], advance: Bool) {
        let idx = changes.indices.filter { paths.contains(changes[$0].path) }
        guard !idx.isEmpty else { return }
        let newValue = !idx.allSatisfy { changes[$0].reviewed }
        for i in idx { changes[i].reviewed = newValue }
        repository.reviews.set(idx.map { changes[$0].diff.change }, reviewed: newValue)
        if newValue, advance, let last = idx.max() {
            let next = changes.indices.first { $0 > last && !changes[$0].reviewed } ?? changes.indices.first { !changes[$0].reviewed }
            if let next {
                if case .overview? = focus { reader.scrollToFile(next) } else { open(changes[next].path, record: false) }
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

    func navigatorOpen(path: String, line: Int?) {
        open(path, at: line.map { .line(SideLine(number: $0, old: false)) } ?? .firstChange, record: focus != .file(path))
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
    func readerOpenFile(_ file: Int, line: Int?) {
        guard reader.files.indices.contains(file) else { return }
        let f = reader.files[file]
        if let line, !f.lines.isEmpty {
            let (n, old) = f.lineNumber(at: line)
            open(f.path, at: .line(SideLine(number: n, old: old)))
        } else {
            open(f.path)
        }
    }

    func readerUnfolded() {}

    func readerJumpToDefinition(_ word: String, file: Int, line: Int) {
        jumpToDefinition(word, from: reader.files.indices.contains(file) ? reader.files[file].path : nil)
    }

    func readerEditNote(_ id: UUID) { editNote(id) }

    func readerAddNote() { addNote(nil) }

    func readerPeek() { peekDefinition(nil) }

    func readerCurrentFileChanged() {
        updateTitle()
        if case .overview? = focus { inspector.follow(lineIndex: reader.currentFile) }
    }

    func readerCaretMoved() {
        if case .file? = focus { inspector.follow(lineIndex: reader.caret?.line) }
        if blameOn { inspector.updateCard(card()) }
    }

    func readerBlameClicked(_ commit: Blame.Commit, line: Int) {
        guard let f = focusedFile else { return }
        let r = Review(subject: .commit(commit.oid))
        select(r, then: Location(review: r, place: .file(f.path), top: SideLine(number: line, old: false), caret: Location.Caret(path: f.path, line: SideLine(number: line, old: false))))
    }
}

extension RepoWindowController: NotesPaneDelegate {
    func notesPaneOpen(_ note: Note) {
        guard let on = note.lines else { return }
        open(on.path, at: .line(SideLine(number: on.range.upperBound, old: on.old)), record: focus != .file(on.path))
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
    func inspectorJump(toLineIndex index: Int) {
        pushHistory()
        reader.land(onLine: index)
    }

    func inspectorShowChange(_ index: Int) {
        guard case .overview? = focus else { return }
        reader.scrollToFile(index)
    }
}
