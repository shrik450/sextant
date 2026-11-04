import AppKit
import RevueCore

/// A place in the history of what was read, as a file (or the overview) at a line, in a target.
struct Location: Equatable {
    enum Place: Equatable {
        /// Every change, with `path` as the file at the top.
        case overview(path: String?)
        case file(String)
    }

    var target: Target
    var place: Place
    /// The 1-based line on the new side, or on the old side for removed lines.
    var line: Int
    var old: Bool
}

/// Where the reader lands in a file it opens.
enum Anchor {
    case firstChange, lastChange, start
    /// A line placed comfortably in view and selected.
    case line(Int, old: Bool)
    /// A line restored to the top of the view, as it was.
    case top(Int, old: Bool)
}

@MainActor
final class RepoWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, SidebarDelegate, FileListDelegate,
    NavigatorDelegate, ReaderDelegate, NSMenuItemValidation
{
    let repo: Repo
    let split = NSSplitViewController()
    let sidebar = SidebarViewController()
    let navigator = Navigator()
    let reader = Reader()
    let notes: NotesStore
    private var watcher: FileWatcher?

    var fileList: FileListViewController { navigator.changes }

    private(set) var target: Target?
    /// The target's changes, in diff order.
    private(set) var changes: [FileState] = []
    /// Files read while exploring the target's snapshot, by path.
    private var explored: [String: FileState] = [:]
    /// What the reader shows: the overview of every change, or one file.
    private(set) var focus: Location.Place?
    private var pendingLocation: Location?
    private var backStack: [Location] = []
    private var forwardStack: [Location] = []
    private var loadGeneration = 0
    private var showGeneration = 0
    private var searchGeneration = 0
    private var blameOn = false
    /// The number of loads in flight.
    ///
    /// Automation waits for this to reach zero.
    private(set) var busy = 0 { didSet { if busy == 0 { RepoWindowController.idleWaiters.forEach { $0() }; RepoWindowController.idleWaiters.removeAll() } } }
    static var idleWaiters: [() -> Void] = []
    private var lastError: String?

    init(repo: Repo) {
        self.repo = repo
        notes = NotesStore.shared(for: repo.commonDir)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 760, height: 420)
        window.title = repo.name
        window.representedURL = repo.root
        window.tabbingMode = .automatic
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        super.init(window: window)
        window.delegate = self

        sidebar.repo = repo
        sidebar.delegate = self
        fileList.delegate = self
        navigator.delegate = self
        navigator.tree.delegate = self
        navigator.search.delegate = self
        navigator.notes.delegate = self
        reader.delegate = self
        reader.split = UserDefaults.standard.string(forKey: "diffMode") == "split"
        reader.wraps = UserDefaults.standard.bool(forKey: "wrapLines")
        reader.notes = notes.notes

        let sideItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sideItem.minimumThickness = 220
        sideItem.maximumThickness = 420
        sideItem.preferredThicknessFraction = 0.17
        sideItem.canCollapse = true
        let navItem = NSSplitViewItem(contentListWithViewController: navigator)
        navItem.minimumThickness = 220
        navItem.maximumThickness = 520
        navItem.preferredThicknessFraction = 0.18
        navItem.canCollapse = true
        let readerItem = NSSplitViewItem(viewController: reader)
        readerItem.minimumThickness = 360
        split.splitViewItems = [sideItem, navItem, readerItem]
        split.splitView.autosaveName = "RevueSplit2"
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1440, height: 900))

        let toolbar = NSToolbar(identifier: "RevueToolbar2")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        window.autorecalculatesKeyViewLoop = false
        sidebar.filter.nextKeyView = sidebar.table
        fileList.filter.nextKeyView = fileList.table
        navigator.tree.filter.nextKeyView = navigator.tree.outline
        navigator.search.field.nextKeyView = navigator.search.outline
        navigator.onTabChanged = { [weak self] in self?.updateKeyLoop() }
        reader.keyLoopNext = sidebar.table
        updateKeyLoop()
        window.initialFirstResponder = reader.firstKeyView

        window.setFrameAutosaveName("RevueWindow")
        if !window.setFrameUsingName("RevueWindow") { window.center() }

        navigator.notes.setNotes(notes.notes)
        NotificationCenter.default.addObserver(self, selector: #selector(reviewsChanged(_:)), name: ReviewStore.didChange, object: repo.reviews)
        NotificationCenter.default.addObserver(self, selector: #selector(notesChanged(_:)), name: NotesStore.didChange, object: notes)
        watcher = FileWatcher(paths: [repo.root.path, repo.commonDir.path]) { [weak self] paths in
            self?.filesystemChanged(paths)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateKeyLoop() {
        sidebar.table.nextKeyView = navigator.focusView
        navigator.focusView.nextKeyView = reader.firstKeyView
    }

    /// Loads refs and history, then the requested target (or a sensible default).
    func start(spec: String?) {
        busy += 1
        Task {
            defer { busy -= 1 }
            let git = repo.git
            async let refreshed = repo.refresh()
            if let spec, !spec.isEmpty {
                await open(spec: spec)
            } else {
                let status = await Repo.loadStatus(git)
                let head = await git.head()
                select(status.uncommitted > 0 || head == nil ? .uncommitted : .commit(head!))
            }
            do { _ = try await refreshed } catch { showError(error) }
            sidebar.reload(preserving: target)
            applyStatusFlags()
            updateTitle()
        }
    }

    func open(spec: String) async {
        do {
            select(try await repo.target(for: spec))
        } catch {
            showError(error)
        }
    }

    /// Reviews a target.
    ///
    /// - Parameter location: Where to land once the target has loaded.
    func select(_ t: Target?, then location: Location? = nil, fromSidebar: Bool = false, record: Bool = true) {
        guard let t else { return }
        if !fromSidebar { sidebar.select(t, notify: false) }
        let isNew = t != target
        if isNew, record, target != nil { pushHistory() }
        if isNew {
            explored = [:]
            lastDiffs = nil
        }
        target = t
        pendingLocation = location
        updateTitle()
        load(keepPosition: !isNew)
    }

    private func load(keepPosition: Bool) {
        guard let t = target else { return }
        loadGeneration += 1
        let gen = loadGeneration
        busy += 1
        Task {
            defer { busy -= 1 }
            do {
                async let diffsR = repo.git.diff(t)
                async let detailR: CommitDetail? = {
                    switch t {
                    case .commit(let c), .stash(let c): return try? await repo.git.commitDetail(c)
                    default: return nil
                    }
                }()
                async let rangeCommitsR: [Commit] = {
                    if case .range(let base, let head, _) = t {
                        return (try? await repo.git.log("\(base)..\(head)", skip: 0, count: 500)) ?? []
                    }
                    return []
                }()
                let diffs = try await diffsR
                let detail = await detailR
                let rangeCommits = await rangeCommitsR
                guard gen == loadGeneration else { return }
                apply(diffs, detail: detail, rangeCommits: rangeCommits, keepPosition: keepPosition)
            } catch {
                guard gen == loadGeneration else { return }
                changes = []
                fileList.setFiles([])
                fileList.setHeader(detail: nil, commits: [])
                focus = nil
                reader.showEmpty(error.localizedDescription)
                lastError = error.localizedDescription
            }
        }
    }

    private var lastDiffs: [FileDiff]?
    private var lastHeaderKey: String?

    private func apply(_ diffs: [FileDiff], detail: CommitDetail?, rangeCommits: [Commit], keepPosition: Bool) {
        let headerKey = (detail?.oid ?? "") + rangeCommits.map(\.oid).joined()
        if keepPosition, pendingLocation == nil, diffs == lastDiffs, headerKey == lastHeaderKey {
            return
        }
        let here = keepPosition ? currentLocation() : nil
        let previous = Dictionary(changes.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let t = target ?? .uncommitted
        changes = diffs.map { d in
            let f = previous[d.path].flatMap { $0.diff == d ? $0 : nil } ?? FileState(diff: d)
            f.reviewed = repo.reviews.isReviewed(d.change)
            f.conflicted = t.includesWorktree && repo.status.conflictedPaths.contains(d.path)
            return f
        }
        if keepPosition, t.snapshot == .worktree { explored = [:] }
        lastDiffs = diffs
        lastHeaderKey = headerKey
        lastError = nil
        fileList.setFiles(changes)
        fileList.setHeader(detail: detail, commits: rangeCommits)
        loadTree()

        if let loc = pendingLocation ?? here {
            pendingLocation = nil
            restore(loc)
        } else if changes.isEmpty {
            focus = nil
            fileList.showCurrent(.none)
            reader.showEmpty(emptyMessage(t))
        } else if UserDefaults.standard.string(forKey: "readerMode") == "overview" && changes.count > 1 {
            showOverview(record: false)
        } else {
            open(changes[0].path, at: .firstChange, record: false)
        }
        updateTitle()
    }

    /// Loads every file in the target's snapshot, for the Files navigator.
    private func loadTree() {
        guard let snapshot = target?.snapshot else { return }
        let changed = Dictionary(changes.filter { !$0.diff.change.isDeleted }.map { ($0.path, $0.diff.change.status) }, uniquingKeysWith: { a, _ in a })
        busy += 1
        Task {
            defer { busy -= 1 }
            let files = (try? await repo.git.files(in: snapshot)) ?? []
            guard target?.snapshot == snapshot else { return }
            navigator.tree.setFiles(files, changed: changed)
            if case .file(let p)? = focus { navigator.tree.reveal(p) }
        }
    }

    private func emptyMessage(_ t: Target) -> String {
        switch t {
        case .uncommitted: "Working tree clean"
        case .staged: "Nothing staged"
        case .unstaged: "No unstaged changes"
        default: "No changes"
        }
    }

    /// The file the reader shows, when it shows one.
    var focusedFile: FileState? {
        guard case .file? = focus else { return nil }
        return reader.files.first
    }

    /// The change under the reader, which is the focused file or the file at the top of the overview.
    private var currentChange: Int? {
        switch focus {
        case .file(let p)?: return changes.firstIndex { $0.path == p }
        case .overview?: return reader.currentFile
        case nil: return nil
        }
    }

    /// Shows one file, which is a change or any file in the target's snapshot.
    func open(_ path: String, at anchor: Anchor = .firstChange, record: Bool = true) {
        guard let t = target else { return }
        if record { pushHistory() }
        focus = .file(path)
        UserDefaults.standard.set("file", forKey: "readerMode")
        showGeneration += 1
        let gen = showGeneration
        let index = changes.firstIndex { $0.path == path }
        fileList.showCurrent(index.map { .file($0) } ?? .none)
        navigator.tree.reveal(path)
        updateTitle()
        busy += 1
        Task {
            defer { busy -= 1 }
            let f = await fileState(path, in: t)
            guard gen == showGeneration else { return }
            guard let f else {
                reader.showEmpty("\(path) isn’t in this revision")
                return
            }
            present(f, at: anchor)
        }
    }

    private func fileState(_ path: String, in t: Target) async -> FileState? {
        if let f = changes.first(where: { $0.path == path }) {
            if !f.isWhole, !f.diff.isBinary, let old = try? await repo.git.oldLines(of: f.diff) {
                f.setWhole(wholeFile(f.diff.hunks, oldLines: old))
            }
            return f
        }
        if let f = explored[path] { return f }
        guard let data = await repo.git.contents(of: path, in: t.snapshot) else { return nil }
        let binary = data.prefix(8000).contains(0)
        let f = FileState(path: path, contents: binary ? nil : splitLines(data))
        if target == t { explored[path] = f }
        return f
    }

    private func present(_ f: FileState, at anchor: Anchor) {
        reader.blame = nil
        switch anchor {
        case .line(let n, let old):
            reader.show(files: [f], overview: false, at: f.index(ofLine: n, old: old).map { ReaderPosition(file: 0, line: $0) })
            if let i = f.index(ofLine: n, old: old) { reader.scroll(to: ReaderPosition(file: 0, line: i), animated: false, select: true) }
        case .top(let n, let old):
            reader.show(files: [f], overview: false)
            if let i = f.index(ofLine: n, old: old) { reader.scroll(to: ReaderPosition(file: 0, line: i), animated: false, offset: 0) }
        case .firstChange:
            reader.show(files: [f], overview: false)
            if f.isChange { reader.scrollToFirstChange() }
        case .lastChange:
            reader.show(files: [f], overview: false)
            if f.isChange { reader.scrollToLastChange() }
        case .start:
            reader.show(files: [f], overview: false)
        }
        if blameOn { loadBlame(f) }
        updateNavButtons()
        updateTitle()
    }

    func showOverview(record: Bool = true, at path: String? = nil, line: Int? = nil, old: Bool = false) {
        guard !changes.isEmpty else { NSSound.beep(); return }
        if record { pushHistory() }
        showGeneration += 1
        focus = .overview(path: nil)
        UserDefaults.standard.set("overview", forKey: "readerMode")
        reader.blame = nil
        reader.show(files: changes, overview: true)
        if let path, let i = changes.firstIndex(where: { $0.path == path }) {
            if let line, let l = changes[i].index(ofLine: line, old: old) {
                reader.scroll(to: ReaderPosition(file: i, line: l), animated: false, offset: 0)
            } else {
                reader.scrollToFile(i)
            }
        }
        fileList.showCurrent(.overview)
        updateNavButtons()
        updateTitle()
    }

    private func currentLocation() -> Location? {
        guard let t = target, let focus else { return nil }
        let pos = reader.topPosition
        let file = pos.flatMap { reader.files.indices.contains($0.file) ? reader.files[$0.file] : nil }
        let (n, old) = file.flatMap { f in f.lines.isEmpty ? nil : f.lineNumber(at: pos!.line) } ?? (1, false)
        switch focus {
        case .overview: return Location(target: t, place: .overview(path: file?.path), line: n, old: old)
        case .file(let p): return Location(target: t, place: .file(p), line: n, old: old)
        }
    }

    private func pushHistory() {
        guard let here = currentLocation() else { return }
        if backStack.last != here { backStack.append(here) }
        if backStack.count > 200 { backStack.removeFirst() }
        forwardStack.removeAll()
        updateNavButtons()
    }

    private func restore(_ loc: Location) {
        if loc.target != target {
            select(loc.target, then: loc, record: false)
            return
        }
        switch loc.place {
        case .overview(let path):
            if changes.isEmpty { reader.showEmpty(emptyMessage(loc.target)); focus = nil } else { showOverview(record: false, at: path, line: loc.line, old: loc.old) }
        case .file(let p):
            open(p, at: .top(loc.line, old: loc.old), record: false)
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

    private func updateNavButtons() {
        navGroup?.subitems[0].isEnabled = !backStack.isEmpty
        navGroup?.subitems[1].isEnabled = !forwardStack.isEmpty
    }

    var targetLabel: String {
        switch target {
        case .uncommitted?: "Uncommitted changes"
        case .staged?: "Staged changes"
        case .unstaged?: "Unstaged changes"
        case .commit(let c)?: repo.commit(c).map { "\($0.shortOid)  \($0.subject)" } ?? String(c.prefix(7))
        case .stash(let s)?: repo.stashes.first { $0.oid == s }.map { "\($0.ref)  \($0.subject)" } ?? "Stash"
        case .range(_, _, let label)?: label
        case nil: ""
        }
    }

    func updateTitle() {
        guard let window else { return }
        window.title = repo.name
        var sub = targetLabel
        if target?.includesIndex == true { sub += "  ·  " + (repo.branch ?? repo.head.map { String($0.prefix(7)) } ?? "no commits") }
        window.subtitle = sub
        let reviewed = currentChange.map { changes[$0].reviewed } ?? false
        reviewItem?.image = NSImage(systemSymbolName: reviewed ? "checkmark.circle.fill" : "checkmark.circle", accessibilityDescription: "Reviewed")
        reviewItem?.toolTip = reviewed ? "Mark as Not Reviewed (R)" : "Mark as Reviewed (R)"
    }

    func showError(_ error: Error) {
        lastError = error.localizedDescription
        guard let window else { return }
        let a = NSAlert()
        a.messageText = error.localizedDescription
        a.alertStyle = .warning
        a.beginSheetModal(for: window)
    }

    private var refreshTask: Task<Void, Never>?

    private func filesystemChanged(_ paths: [String]) {
        let common = repo.commonDir.path
        let relevant = paths.contains { p in
            if p.hasPrefix(common + "/objects") || p.hasPrefix(common + "/revue") || p.hasPrefix(common + "/lfs") { return false }
            if p.hasSuffix(".lock") || p.contains("/.git/objects/") { return false }
            if p.hasPrefix(common + "/logs") { return false }
            return true
        }
        guard relevant else { return }
        refresh()
    }

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            busy += 1
            defer { busy -= 1 }
            let changed = (try? await repo.refresh()) ?? false
            if changed { sidebar.reload(preserving: target) }
            applyStatusFlags()
            if let t = target, t.includesIndex || changed { load(keepPosition: true) }
            updateTitle()
        }
    }

    /// Applies flags derived from `git status` that the diff itself doesn't carry.
    private func applyStatusFlags() {
        let worktree = target?.includesWorktree == true
        var changed = false
        for f in changes {
            let c = worktree && repo.status.conflictedPaths.contains(f.path)
            if f.conflicted != c { f.conflicted = c; changed = true }
        }
        if changed { fileList.refreshReviewState() }
    }

    @objc private func reviewsChanged(_ n: Notification) {
        for f in changes { f.reviewed = repo.reviews.isReviewed(f.diff.change) }
        fileList.refreshReviewState()
        if case .overview? = focus { reader.reload(keepPosition: true) }
        updateTitle()
    }

    func toggleReviewed(_ idx: [Int], advance: Bool) {
        let valid = idx.filter { $0 < changes.count }
        guard !valid.isEmpty else { return }
        let newValue = !valid.allSatisfy { changes[$0].reviewed }
        for i in valid { changes[i].reviewed = newValue }
        repo.reviews.set(valid.map { changes[$0].diff.change }, reviewed: newValue)
        if newValue, advance, let last = valid.max() {
            let next = changes.indices.first { $0 > last && !changes[$0].reviewed } ?? changes.indices.first { !changes[$0].reviewed }
            if let next {
                if case .overview? = focus { reader.scrollToFile(next) } else { open(changes[next].path, record: false) }
            }
        }
        updateTitle()
    }

    func sidebarSelected(_ t: Target?) { select(t, fromSidebar: true) }

    private var loadingMore = false
    func sidebarLoadMore() {
        guard !loadingMore else { return }
        loadingMore = true
        Task {
            defer { loadingMore = false }
            if (try? await repo.loadMoreCommits()) == true { sidebar.reload(preserving: target) }
        }
    }

    func sidebarContextMenu(for t: Target) -> NSMenu? {
        let m = NSMenu()
        var oid: String?
        switch t {
        case .commit(let c), .stash(let c): oid = c
        case .range(_, let h, _): oid = h
        default: break
        }
        if let oid { add(m, "Copy Commit Hash", #selector(copyString(_:)), oid) }
        if case .commit(let c) = t, let commit = repo.commit(c) {
            add(m, "Mark Commit as Reviewed", #selector(markCommit(_:)), [commit.oid, true] as [Any])
            add(m, "Mark Commit as Not Reviewed", #selector(markCommit(_:)), [commit.oid, false] as [Any])
        }
        return m.items.isEmpty ? nil : m
    }

    private func add(_ m: NSMenu, _ title: String, _ sel: Selector, _ obj: Any? = nil) {
        let item = m.addItem(withTitle: title, action: sel, keyEquivalent: "")
        item.target = self
        item.representedObject = obj
    }

    @objc private func copyString(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String else { return }
        copy(s)
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    @objc private func markCommit(_ sender: NSMenuItem) {
        guard let arr = sender.representedObject as? [Any], let oid = arr[0] as? String, let v = arr[1] as? Bool, let c = repo.commit(oid) else { return }
        repo.reviews.set(c.changes, reviewed: v)
    }

    func fileListSelected(_ file: Int) {
        guard file < changes.count else { return }
        if case .file(let p)? = focus, p == changes[file].path { return }
        open(changes[file].path)
    }

    func fileListSelectedOverview() {
        if case .overview? = focus { return }
        showOverview()
    }

    func fileListToggleReviewed(_ idx: [Int]) { toggleReviewed(idx, advance: false) }

    func fileListContextMenu(_ idx: [Int]) -> NSMenu? {
        let m = NSMenu()
        let reviewed = idx.allSatisfy { changes[$0].reviewed }
        add(m, reviewed ? "Mark as Not Reviewed" : "Mark as Reviewed", #selector(menuToggleReviewed(_:)), idx)
        m.addItem(.separator())
        if idx.count == 1 {
            fileItems(m, path: changes[idx[0]].path)
        } else {
            add(m, "Copy Paths", #selector(copyString(_:)), idx.map { changes[$0].path }.joined(separator: "\n"))
        }
        return m
    }

    private func fileItems(_ m: NSMenu, path: String) {
        add(m, "Open in Editor", #selector(menuOpenInEditor(_:)), [path, 0] as [Any])
        add(m, "Reveal in Finder", #selector(menuReveal(_:)), path)
        add(m, "Copy Path", #selector(copyString(_:)), path)
    }

    @objc private func menuToggleReviewed(_ sender: NSMenuItem) {
        guard let idx = sender.representedObject as? [Int] else { return }
        toggleReviewed(idx, advance: false)
    }

    @objc private func menuOpenInEditor(_ sender: NSMenuItem) {
        guard let a = sender.representedObject as? [Any], let path = a[0] as? String else { return }
        openInEditor(path: path, line: a[1] as? Int ?? 0)
    }

    @objc private func menuReveal(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        let url = repo.root.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSSound.beep()
        }
    }

    /// Opens the working copy of a file, which may differ from the revision being read.
    func openInEditor(path: String, line: Int) {
        let url = repo.root.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { NSSound.beep(); return }
        if let cmd = UserDefaults.standard.string(forKey: "editorCommand"), !cmd.trimmingCharacters(in: .whitespaces).isEmpty {
            let full = cmd.replacingOccurrences(of: "{file}", with: shellQuote(url.path)).replacingOccurrences(of: "{line}", with: String(max(1, line)))
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", full]
            p.currentDirectoryURL = repo.root
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = userPath()
            p.environment = env
            do { try p.run() } catch { showError(error) }
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func navigatorOpen(path: String, line: Int?) {
        let samePath = focus == .file(path)
        open(path, at: line.map { .line($0, old: false) } ?? .firstChange, record: !samePath)
    }

    func navigatorSearch(_ query: String, word: Bool, caseSensitive: Bool) {
        guard let t = target else { return }
        searchGeneration += 1
        let gen = searchGeneration
        busy += 1
        Task {
            defer { busy -= 1 }
            do {
                let m = try await repo.git.grep(query, in: t.snapshot, word: word, ignoreCase: !caseSensitive, maxPerFile: 100)
                guard gen == searchGeneration else { return }
                let limit = 5000
                navigator.search.show(Array(m.prefix(limit)), title: query, capped: m.count > limit)
            } catch {
                guard gen == searchGeneration else { return }
                navigator.search.status.stringValue = error.localizedDescription
            }
        }
    }

    func navigatorOpenNote(_ note: Note) {
        open(note.path, at: .line(note.lines.upperBound, old: note.old), record: focus != .file(note.path))
    }

    func navigatorDeleteNotes(_ ids: Set<UUID>) { notes.remove(ids) }

    func navigatorFocusReader() { reader.focus() }

    func navigatorCopyNotes(_ selection: [Note]?) {
        guard !(selection ?? notes.notes).isEmpty else { NSSound.beep(); return }
        copy(notes.markdown(selection))
    }

    @objc private func notesChanged(_ n: Notification) {
        reader.notes = notes.notes
        reader.reload(keepPosition: true)
        navigator.notes.setNotes(notes.notes)
    }

    /// Finds where a name is defined, the way GitHub does it.
    ///
    /// Finds the word with `git grep`, then keeps the places the language's tags query says
    /// define it.
    private func lookUp(_ word: String, in t: Target) async throws -> (matches: [GrepMatch], definitions: [GrepMatch]) {
        let snapshot = t.snapshot
        let git = repo.git
        let matches = try await git.grep(word, in: snapshot, word: true, ignoreCase: false, maxPerFile: 200)
        var langs: [(String, SyntaxLanguage)] = []
        for p in Set(matches.map(\.path)).sorted() {
            if let l = SyntaxRuntime.shared?.language(forPath: p), l.hasTags { langs.append((p, l)) }
            if langs.count >= 200 { break }
        }
        let definitions = await withTaskGroup(of: [GrepMatch].self) { group in
            for (path, lang) in langs {
                group.addTask {
                    guard let data = await git.contents(of: path, in: snapshot) else { return [] }
                    let text = String(decoding: data, as: UTF8.self)
                    let defs = lang.symbols(text).filter { $0.isDefinition && $0.name == word }
                    guard !defs.isEmpty else { return [] }
                    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                    return defs.map { d in
                        GrepMatch(path: path, line: d.nameLine + 1, column: 1, text: d.nameLine < lines.count ? String(lines[d.nameLine]) : word)
                    }
                }
            }
            var out: [GrepMatch] = []
            for await d in group { out += d }
            var seen = Set<String>()
            return out.filter { seen.insert("\($0.path):\($0.line)").inserted }
        }
        return (matches, definitions)
    }

    /// Sorts definitions nearest first: the same file, then files sharing the most directories.
    private func nearest(_ defs: [GrepMatch], to path: String?) -> [GrepMatch] {
        guard let path else { return defs.sorted { ($0.path, $0.line) < ($1.path, $1.line) } }
        let here = path.split(separator: "/")
        func closeness(_ p: String) -> Int {
            if p == path { return Int.max }
            return zip(here, p.split(separator: "/")).prefix { $0 == $1 }.count
        }
        return defs.sorted { a, b in
            let ca = closeness(a.path), cb = closeness(b.path)
            return ca != cb ? ca > cb : (a.path, a.line) < (b.path, b.line)
        }
    }

    func jumpToDefinition(_ word: String, from path: String?) {
        guard let t = target else { return }
        searchGeneration += 1
        let gen = searchGeneration
        busy += 1
        Task {
            defer { busy -= 1 }
            guard let (matches, definitions) = try? await lookUp(word, in: t), gen == searchGeneration else { return }
            let defs = nearest(definitions, to: path)
            if defs.count == 1 {
                open(defs[0].path, at: .line(defs[0].line, old: false))
                return
            }
            revealNavigator(.search)
            navigator.search.begin(word, word: true)
            if defs.isEmpty {
                navigator.search.show(Array(matches.prefix(5000)), title: word, capped: matches.count > 5000)
                navigator.search.status.stringValue = "No definition found. " + navigator.search.status.stringValue
            } else {
                navigator.search.show(defs, title: word, capped: false)
                navigator.search.status.stringValue = "\(defs.count) definitions of \(word)"
            }
        }
    }

    func findReferences(_ word: String) {
        guard let t = target else { return }
        revealNavigator(.search)
        navigator.search.begin(word, word: true)
        searchGeneration += 1
        let gen = searchGeneration
        busy += 1
        Task {
            defer { busy -= 1 }
            guard let (matches, definitions) = try? await lookUp(word, in: t), gen == searchGeneration else { return }
            let defLines = Dictionary(grouping: definitions, by: \.path).mapValues { Set($0.map(\.line)) }
            navigator.search.show(Array(matches.prefix(5000)), title: word, definitions: defLines, capped: matches.count > 5000)
        }
    }

    private func revealNavigator(_ tab: Navigator.Tab, focus: Bool = false) {
        let item = split.splitViewItems[1]
        if item.isCollapsed { item.animator().isCollapsed = false }
        navigator.show(tab, focus: focus)
    }

    private func loadBlame(_ f: FileState) {
        guard let t = target, !f.diff.change.isDeleted, !f.diff.isBinary else { return }
        let path = f.path
        busy += 1
        Task {
            defer { busy -= 1 }
            let b = try? await repo.git.blame(path, in: t.snapshot)
            guard blameOn, target == t, focusedFile === f else { return }
            reader.blame = b
        }
    }

    @objc func toggleBlame(_ sender: Any?) {
        blameOn.toggle()
        if blameOn, let f = focusedFile { loadBlame(f) } else { reader.blame = nil }
    }

    /// Lists the commits that touched the focused file, newest first.
    ///
    /// Choosing one reads the file at that commit.
    @objc func showFileHistory(_ sender: Any?) {
        guard let f = focusedFile, let t = target else { NSSound.beep(); return }
        let from: String = switch t.snapshot {
        case .commit(let c): c
        default: "HEAD"
        }
        let path = f.path
        busy += 1
        Task {
            defer { busy -= 1 }
            let commits = (try? await repo.git.history(of: path, from: from, count: 100)) ?? []
            let m = NSMenu()
            m.addItem(withTitle: "History of \((path as NSString).lastPathComponent)", action: nil, keyEquivalent: "").isEnabled = false
            if commits.isEmpty { m.addItem(withTitle: "No commits", action: nil, keyEquivalent: "").isEnabled = false }
            for c in commits {
                let item = m.addItem(withTitle: "", action: #selector(openHistoryCommit(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = [c.oid, path]
                let s = NSMutableAttributedString(string: c.shortOid + "  ", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor])
                s.append(NSAttributedString(string: c.subject.count > 70 ? c.subject.prefix(69) + "…" : c.subject, attributes: [.font: NSFont.menuFont(ofSize: 13)]))
                s.append(NSAttributedString(string: "  " + compactDate(c.date) + "  " + c.author, attributes: [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
                item.attributedTitle = s
                if case .commit(let cur) = t, cur == c.oid { item.state = .on }
            }
            let bar = reader.jumpBar
            m.popUp(positioning: nil, at: NSPoint(x: 8, y: bar.isFlipped ? bar.bounds.maxY : bar.bounds.minY), in: bar)
        }
    }

    @objc private func openHistoryCommit(_ sender: NSMenuItem) {
        guard let a = sender.representedObject as? [String], a.count == 2 else { return }
        let line = currentLocation()?.line ?? 1
        let t = Target.commit(a[0])
        select(t, then: Location(target: t, place: .file(a[1]), line: line, old: false))
    }

    func readerOpenFile(_ file: Int, line: Int?) {
        guard reader.files.indices.contains(file) else { return }
        let f = reader.files[file]
        if let line, !f.lines.isEmpty {
            let (n, old) = f.lineNumber(at: line)
            open(f.path, at: .line(n, old: old))
        } else {
            open(f.path)
        }
    }

    func readerUnfolded() {}

    func readerJumpToDefinition(_ word: String, file: Int, line: Int) {
        jumpToDefinition(word, from: reader.files.indices.contains(file) ? reader.files[file].path : nil)
    }

    func readerEditNote(_ id: UUID) { editNote(id) }

    func readerMenu(file: Int?, line: Int?) -> NSMenu? {
        let m = NSMenu()
        if line != nil {
            add(m, "Copy Reference", #selector(copyReference(_:)))
            add(m, "Copy Reference with Code", #selector(copyReferenceWithCode(_:)))
            add(m, "Add Note", #selector(addNote(_:)))
            if let w = reader.wordAtCaret, w.count < 100 {
                m.addItem(.separator())
                add(m, "Jump to Definition", #selector(jumpToDefinitionAction(_:)))
                add(m, "Find References", #selector(findReferencesAction(_:)))
            }
            m.addItem(.separator())
        }
        if let file, reader.files.indices.contains(file) {
            let f = reader.files[file]
            if let i = changes.firstIndex(where: { $0 === f }) {
                add(m, f.reviewed ? "Mark as Not Reviewed" : "Mark as Reviewed", #selector(menuToggleReviewed(_:)), [i])
                m.addItem(.separator())
            }
            let n = line.map { f.lineNumber(at: $0).number } ?? 0
            add(m, "Open in Editor", #selector(menuOpenInEditor(_:)), [f.path, n] as [Any])
            add(m, "Reveal in Finder", #selector(menuReveal(_:)), f.path)
        }
        return m
    }

    func readerCurrentFileChanged() { updateTitle() }

    func readerBlameClicked(_ commit: Blame.Commit, line: Int) {
        guard let f = focusedFile else { return }
        let t = Target.commit(commit.oid)
        select(t, then: Location(target: t, place: .file(f.path), line: line, old: false))
    }

    /// The selected lines, or the line at the insertion point.
    private var selectedReference: (path: String, lines: ClosedRange<Int>, old: Bool, code: [String], file: Int, line: Int)? {
        guard let sel = reader.selection, reader.files.indices.contains(sel.file), let last = sel.lines.last else { return nil }
        let f = reader.files[sel.file]
        guard let r = f.reference(sel.lines) else { return nil }
        return (f.path, r.lines, r.old, r.code, sel.file, last)
    }

    @objc func copyReference(_ sender: Any?) {
        guard let r = selectedReference else { NSSound.beep(); return }
        copy(lineReference(path: r.path, lines: r.lines, old: r.old))
    }

    @objc func copyReferenceWithCode(_ sender: Any?) {
        guard let r = selectedReference else { NSSound.beep(); return }
        let lang = SyntaxRuntime.shared?.language(forPath: r.path)?.name ?? ""
        copy("`\(lineReference(path: r.path, lines: r.lines, old: r.old))`\n```\(lang)\n\(r.code.joined(separator: "\n"))\n```\n")
    }

    /// Copies the name of the symbol under the insertion point, or of the definition around it.
    @objc func copySymbol(_ sender: Any?) {
        if let w = reader.wordAtCaret, w.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "$" }) {
            copy(w)
        } else if let r = selectedReference, !r.old, let s = reader.jumpBar.enclosing(line: r.lines.lowerBound - 1) {
            copy(s.name)
        } else {
            NSSound.beep()
        }
    }

    @objc func addNote(_ sender: Any?) {
        guard let r = selectedReference, let (rect, view) = reader.rect(file: r.file, line: r.line) else { NSSound.beep(); return }
        let context = targetLabel
        let editor = NoteEditor(reference: lineReference(path: r.path, lines: r.lines, old: r.old), text: "", canDelete: false) { [weak self] text in
            self?.notes.add(Note(path: r.path, lines: r.lines, old: r.old, text: text, code: r.code, context: context))
        }
        editor.show(relativeTo: rect, of: view)
    }

    func editNote(_ id: UUID) {
        guard let note = notes.notes.first(where: { $0.id == id }), let (rect, view) = reader.rect(ofNote: id) else { return }
        let editor = NoteEditor(reference: note.reference, text: note.text, canDelete: true, onSave: { [weak self] text in
            var n = note
            n.text = text
            self?.notes.update(n)
        }, onDelete: { [weak self] in self?.notes.remove([id]) })
        editor.show(relativeTo: rect, of: view)
    }

    @objc func copyAllNotes(_ sender: Any?) { navigatorCopyNotes(nil) }

    static let navID = NSToolbarItem.Identifier("nav")
    static let readerSeparatorID = NSToolbarItem.Identifier("readerSeparator")
    static let diffModeID = NSToolbarItem.Identifier("diffMode")
    static let reviewID = NSToolbarItem.Identifier("review")
    private weak var reviewItem: NSToolbarItem?
    private weak var modeGroup: NSToolbarItemGroup?
    private weak var navGroup: NSToolbarItemGroup?

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, RepoWindowController.readerSeparatorID,
         RepoWindowController.navID, .flexibleSpace, RepoWindowController.diffModeID, RepoWindowController.reviewID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case RepoWindowController.readerSeparatorID:
            return NSTrackingSeparatorToolbarItem(identifier: id, splitView: split.splitView, dividerIndex: 1)
        case RepoWindowController.navID:
            let g = NSToolbarItemGroup(itemIdentifier: id,
                                       images: [NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")!,
                                                NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")!],
                                       selectionMode: .momentary, labels: ["Back", "Forward"], target: self, action: #selector(navClicked(_:)))
            g.subitems[0].toolTip = "Back (⌘[)"
            g.subitems[1].toolTip = "Forward (⌘])"
            g.subitems.forEach { $0.autovalidates = false }
            navGroup = g
            updateNavButtons()
            return g
        case RepoWindowController.diffModeID:
            let g = NSToolbarItemGroup(itemIdentifier: id,
                                       images: [NSImage(systemSymbolName: "text.justify.leading", accessibilityDescription: "Unified")!,
                                                NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Side by Side")!],
                                       selectionMode: .selectOne, labels: ["Unified", "Side by Side"], target: self, action: #selector(modeChanged(_:)))
            g.selectedIndex = reader.split ? 1 : 0
            g.subitems[0].toolTip = "Unified (⌃⌘1)"
            g.subitems[1].toolTip = "Side by Side (⌃⌘2)"
            modeGroup = g
            return g
        case RepoWindowController.reviewID:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "Reviewed")
            item.label = "Reviewed"
            item.target = self
            item.action = #selector(toggleReviewedAction(_:))
            item.toolTip = "Mark as Reviewed (R)"
            reviewItem = item
            return item
        default:
            return nil
        }
    }

    @objc private func navClicked(_ sender: NSToolbarItemGroup) {
        sender.selectedIndex == 0 ? goBack(nil) : goForward(nil)
    }

    @objc private func modeChanged(_ sender: NSToolbarItemGroup) { setSplit(sender.selectedIndex == 1) }

    func setSplit(_ on: Bool) {
        reader.split = on
        reader.reload(keepPosition: true)
        modeGroup?.selectedIndex = on ? 1 : 0
        UserDefaults.standard.set(on ? "split" : "unified", forKey: "diffMode")
    }

    /// Moves to the next change, continuing into the next changed file at the end of this one.
    @objc func nextChange(_ sender: Any?) {
        if reader.nextChange(1) { return }
        stepFile(1, anchor: .firstChange)
    }

    @objc func previousChange(_ sender: Any?) {
        if reader.nextChange(-1) { return }
        stepFile(-1, anchor: .lastChange)
    }

    @objc func nextFile(_ sender: Any?) {
        if case .overview? = focus { if !reader.nextFile(1) { NSSound.beep() }; return }
        stepFile(1, anchor: .firstChange)
    }

    @objc func previousFile(_ sender: Any?) {
        if case .overview? = focus { if !reader.nextFile(-1) { NSSound.beep() }; return }
        stepFile(-1, anchor: .firstChange)
    }

    private func stepFile(_ dir: Int, anchor: Anchor) {
        guard case .file(let p)? = focus else { NSSound.beep(); return }
        let cur = changes.firstIndex { $0.path == p }
        let next: Int? = if let cur { cur + dir } else { dir > 0 ? 0 : changes.count - 1 }
        guard let next, changes.indices.contains(next) else { NSSound.beep(); return }
        open(changes[next].path, at: anchor, record: false)
    }

    @objc func olderCommit(_ sender: Any?) { sidebar.step(1) }
    @objc func newerCommit(_ sender: Any?) { sidebar.step(-1) }
    @objc func showUncommitted(_ sender: Any?) { select(.uncommitted) }
    @objc func showBranch(_ sender: Any?) {
        if let base = repo.branchBase, let head = repo.head, let d = repo.defaultBranch {
            select(.range(base: base, head: head, label: "\(d)...\(repo.branch ?? String(head.prefix(7)))"))
        } else { NSSound.beep() }
    }

    @objc func showAllChanges(_ sender: Any?) { showOverview() }

    private var actionFiles: [Int] {
        if window?.firstResponder === fileList.table, !fileList.selectedFiles.isEmpty { return fileList.selectedFiles }
        return currentChange.map { [$0] } ?? []
    }

    @objc func toggleReviewedAction(_ sender: Any?) {
        let idx = actionFiles
        guard !idx.isEmpty else { NSSound.beep(); return }
        toggleReviewed(idx, advance: window?.firstResponder !== fileList.table)
    }

    @objc func markAllReviewed(_ sender: Any?) {
        guard !changes.isEmpty else { return }
        repo.reviews.set(changes.map(\.diff.change), reviewed: true)
    }

    @objc func markAllNotReviewed(_ sender: Any?) {
        guard !changes.isEmpty else { return }
        repo.reviews.set(changes.map(\.diff.change), reviewed: false)
    }

    @objc func nextUnreviewed(_ sender: Any?) {
        let cur = currentChange ?? -1
        guard let next = changes.indices.first(where: { $0 > cur && !changes[$0].reviewed }) ?? changes.indices.first(where: { !changes[$0].reviewed }) else {
            NSSound.beep()
            return
        }
        if case .overview? = focus { reader.scrollToFile(next) } else { open(changes[next].path, record: false) }
    }

    @objc func toggleShowAll(_ sender: Any?) {
        reader.showAll.toggle()
        reader.reload(keepPosition: true)
    }

    @objc func toggleWrap(_ sender: Any?) {
        reader.wraps.toggle()
        UserDefaults.standard.set(reader.wraps, forKey: "wrapLines")
        reader.reload(keepPosition: true)
    }

    @objc func showUnified(_ sender: Any?) { setSplit(false) }
    @objc func showSideBySide(_ sender: Any?) { setSplit(true) }
    @objc func refreshAction(_ sender: Any?) { refresh() }

    @objc func toggleNavigator(_ sender: Any?) {
        split.splitViewItems[1].animator().isCollapsed.toggle()
    }

    @objc func showChangesTab(_ sender: Any?) { revealNavigator(.changes, focus: true) }
    @objc func showFilesTab(_ sender: Any?) { revealNavigator(.files, focus: true) }
    @objc func showSearchTab(_ sender: Any?) { revealNavigator(.search, focus: true) }
    @objc func showNotesTab(_ sender: Any?) { revealNavigator(.notes, focus: true) }

    @objc func openQuickly(_ sender: Any?) {
        revealNavigator(.files, focus: true)
        navigator.tree.filter.selectText(nil)
    }

    @objc func findInRepository(_ sender: Any?) {
        let selected = reader.isFocused ? reader.selectedText : nil
        revealNavigator(.search, focus: true)
        if let s = selected, !s.contains("\n"), s.count < 200 {
            navigator.search.field.stringValue = s
            navigator.search.run()
        }
        navigator.search.field.selectText(nil)
    }

    @objc func jumpToDefinitionAction(_ sender: Any?) {
        guard let w = reader.wordAtCaret else { NSSound.beep(); return }
        jumpToDefinition(w, from: reader.selection.map { reader.files[$0.file].path })
    }

    @objc func findReferencesAction(_ sender: Any?) {
        guard let w = reader.wordAtCaret else { NSSound.beep(); return }
        findReferences(w)
    }

    @objc func showSymbols(_ sender: Any?) { reader.jumpBar.showSymbolMenu() }

    @objc func focusSidebar(_ sender: Any?) {
        if split.splitViewItems[0].isCollapsed { split.splitViewItems[0].isCollapsed = false }
        window?.makeFirstResponder(sidebar.table)
    }

    @objc func focusNavigator(_ sender: Any?) {
        if split.splitViewItems[1].isCollapsed { split.splitViewItems[1].isCollapsed = false }
        window?.makeFirstResponder(navigator.focusView)
    }

    @objc func focusReader(_ sender: Any?) { reader.focus() }

    @objc func focusFilter(_ sender: Any?) {
        if (window?.firstResponder as? NSView)?.isDescendant(of: sidebar.view) == true {
            window?.makeFirstResponder(sidebar.filter)
        } else {
            revealNavigator(navigator.tab == .files ? .files : .changes)
            window?.makeFirstResponder(navigator.tab == .files ? navigator.tree.filter : fileList.filter)
        }
    }

    @objc func openCurrentInEditor(_ sender: Any?) {
        let path = focusedFile?.path ?? actionFiles.first.map { changes[$0].path }
        guard let path else { NSSound.beep(); return }
        let line = selectedReference.map { $0.old ? 0 : $0.lines.lowerBound } ?? 0
        openInEditor(path: path, line: line)
    }

    @objc func copyCurrentPath(_ sender: Any?) {
        if window?.firstResponder === fileList.table, !fileList.selectedFiles.isEmpty {
            copy(fileList.selectedFiles.map { changes[$0].path }.joined(separator: "\n"))
        } else if let p = focusedFile?.path ?? currentChange.map({ changes[$0].path }) {
            copy(p)
        } else {
            NSSound.beep()
        }
    }

    private var sheet: RevisionSheet?

    @objc func goToRevision(_ sender: Any?) {
        guard let window, sheet == nil else { return }
        Task {
            let refs = ((try? await repo.git.string(["for-each-ref", "--sort=-creatordate", "--format=%(refname:short)", "refs/heads", "refs/tags", "refs/remotes"])) ?? "")
                .split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/HEAD") }
            let s = RevisionSheet(suggestions: ["staged", "unstaged", "uncommitted"] + refs + repo.stashes.map(\.ref),
                                  initial: UserDefaults.standard.string(forKey: "lastRevision") ?? "") { [weak self] spec in
                guard let self else { return nil }
                do {
                    let t = try await self.repo.target(for: spec)
                    UserDefaults.standard.set(spec, forKey: "lastRevision")
                    self.select(t)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }
            sheet = s
            s.present(on: window) { [weak self] _ in self?.sheet = nil }
        }
    }

    @objc func goToLine(_ sender: Any?) {
        guard let window, sheet == nil, let f = focusedFile, !f.lines.isEmpty else { NSSound.beep(); return }
        let last = f.lines.last.map { max($0.newNo, $0.oldNo) } ?? 1
        let s = RevisionSheet(title: "Go to Line", placeholder: "1–\(last)", suggestions: [], initial: "") { [weak self] text in
            guard let self, let n = Int(text.trimmingCharacters(in: .whitespaces)), n >= 1 else { return "Enter a line number" }
            self.open(f.path, at: .line(min(n, last), old: false), record: true)
            return nil
        }
        sheet = s
        s.present(on: window) { [weak self] _ in self?.sheet = nil }
    }

    override func performTextFinderAction(_ sender: Any?) {
        reader.performFind(sender)
    }

    @objc func biggerFont(_ sender: Any?) { Appearance.shared.adjustFontSize(1) }
    @objc func smallerFont(_ sender: Any?) { Appearance.shared.adjustFontSize(-1) }
    @objc func actualSizeFont(_ sender: Any?) { Appearance.shared.resetFontSize() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.keyEquivalentModifierMask.subtracting(.shift).isEmpty, !item.keyEquivalent.isEmpty,
           let text = window?.firstResponder as? NSTextView, text.isEditable {
            return false
        }
        let reading = focusedFile != nil
        switch item.action {
        case #selector(showUnified(_:)): item.state = reader.split ? .off : .on
        case #selector(showSideBySide(_:)): item.state = reader.split ? .on : .off
        case #selector(toggleWrap(_:)): item.state = reader.wraps ? .on : .off
        case #selector(toggleShowAll(_:)): item.state = reader.showAll ? .on : .off
        case #selector(toggleBlame(_:)):
            item.state = blameOn ? .on : .off
            return reading
        case #selector(toggleReviewedAction(_:)):
            let idx = actionFiles
            item.title = !idx.isEmpty && idx.allSatisfy({ changes[$0].reviewed }) ? "Mark as Not Reviewed" : "Mark as Reviewed"
            return !idx.isEmpty
        case #selector(toggleNavigator(_:)):
            item.title = split.splitViewItems[1].isCollapsed ? "Show Navigator" : "Hide Navigator"
        case #selector(showBranch(_:)): return repo.branchBase != nil
        case #selector(goBack(_:)): return !backStack.isEmpty
        case #selector(goForward(_:)): return !forwardStack.isEmpty
        case #selector(goToLine(_:)), #selector(showFileHistory(_:)), #selector(showSymbols(_:)): return reading
        case #selector(copyReference(_:)), #selector(copyReferenceWithCode(_:)), #selector(addNote(_:)): return reader.selection != nil
        case #selector(jumpToDefinitionAction(_:)), #selector(findReferencesAction(_:)), #selector(copySymbol(_:)): return reader.wordAtCaret != nil || reading
        case #selector(copyAllNotes(_:)): return !notes.notes.isEmpty
        case #selector(nextChange(_:)), #selector(previousChange(_:)), #selector(nextFile(_:)), #selector(previousFile(_:)),
             #selector(markAllReviewed(_:)), #selector(markAllNotReviewed(_:)), #selector(nextUnreviewed(_:)), #selector(showAllChanges(_:)):
            return !changes.isEmpty
        case #selector(openCurrentInEditor(_:)), #selector(copyCurrentPath(_:)): return reading || currentChange != nil
        default: break
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        watcher = nil
        (NSApp.delegate as? AppDelegate)?.windowClosed(self)
    }

    private var focusName: String {
        guard let r = window?.firstResponder else { return "" }
        let editing = (r as? NSTextView)?.delegate as? NSView
        switch editing ?? (r as? NSView) {
        case sidebar.table: return "sidebar"
        case sidebar.filter: return "sidebarFilter"
        case fileList.table: return "changes"
        case fileList.filter: return "changesFilter"
        case navigator.tree.outline: return "files"
        case navigator.tree.filter: return "filesFilter"
        case navigator.search.outline: return "search"
        case navigator.search.field: return "searchField"
        case navigator.notes.table: return "notes"
        default: return r is CodeView ? "reader" : String(describing: type(of: r))
        }
    }

    func stateSnapshot() -> [String: Any] {
        var t = ""
        switch target {
        case .uncommitted?: t = "uncommitted"
        case .staged?: t = "staged"
        case .unstaged?: t = "unstaged"
        case .commit(let c)?: t = "commit:\(c)"
        case .stash(let s)?: t = "stash:\(s)"
        case .range(let b, let h, let l)?: t = "range:\(b)..\(h) (\(l))"
        case nil: t = "none"
        }
        let focusString: String = switch focus {
        case .overview?: "overview"
        case .file(let p)?: "file:\(p)"
        case nil: ""
        }
        let loc = currentLocation()
        return [
            "repo": repo.root.path,
            "target": t,
            "subtitle": window?.subtitle ?? "",
            "error": lastError ?? "",
            "split": reader.split,
            "columns": reader.primary.side == 1 ? 2 : 1,
            "focus": focusString,
            "top": loc.map { "\($0.line)\($0.old ? " (old)" : "")" } ?? "",
            "currentChange": currentChange.map { changes[$0].path } ?? "",
            "isWhole": focusedFile?.isWhole ?? false,
            "rows": reader.primary.rows.count,
            "visibleCodeRect": NSStringFromRect(reader.primary.visibleRect),
            "firstResponder": focusName,
            "windowFrame": NSStringFromRect(window?.frame ?? .zero),
            "isKey": window?.isKeyWindow ?? false,
            "files": changes.map { ["path": $0.path, "status": String($0.diff.change.status), "reviewed": $0.reviewed, "add": $0.diff.additions, "del": $0.diff.deletions] },
            "changesSelection": fileList.selectedFiles.map { changes[$0].path },
            "navigatorTab": "\(navigator.tab)",
            "searchStatus": navigator.search.status.stringValue,
            "notes": notes.notes.map(\.reference),
            "back": backStack.count,
            "forward": forwardStack.count,
            "blame": reader.blame != nil,
            "selectedText": reader.selectedText ?? "",
            "symbol": reader.jumpBar.symbols.isHidden ? "" : reader.jumpBar.symbols.titleOfSelectedItem ?? "",
            "header": fileList.header.isHidden ? "" : fileList.header.stringValue,
            "visibleRows": visibleRowsInWindow(),
            "fontSize": Appearance.shared.font.pointSize,
            "sidebarRows": sidebar.table.numberOfRows,
            "commits": repo.commits.count,
        ]
    }

    /// Returns the visible reader rows with window coordinates (top-left origin), for scripted clicks.
    func visibleRowsInWindow() -> [[String: Any]] {
        guard let cv = window?.contentView else { return [] }
        let code = reader.primary
        var out: [[String: Any]] = []
        code.visibleRows(in: code.visibleRect) { r, frag in
            guard out.count < 80 else { return }
            let row = code.rows[r]
            let kind: String = switch row.kind {
            case .line: {
                let l = code.files[row.file].lines[row.line]
                let sign = l.kind == .added ? "+" : l.kind == .deleted ? "-" : " "
                return "\(sign)\(l.kind == .deleted ? l.oldNo : l.newNo) \(l.text.prefix(40))"
            }()
            case .filler: "filler"
            case .fold(let range): "fold \(range.count)"
            case .gap: "gap"
            case .header: "header \(code.files[row.file].path)"
            case .notice(let s): "notice \(s)"
            case .note: "note"
            }
            let rect = code.convert(frag, to: nil)
            out.append(["kind": kind, "y": cv.bounds.height - rect.midY, "x": rect.minX + 40])
        }
        return out
    }
}

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

/// Returns a PATH for launching user tools from a GUI app.
///
/// A GUI app doesn't inherit the login shell's PATH.
func userPath() -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let user = NSUserName()
    let extra = ["\(home)/.nix-profile/bin", "/etc/profiles/per-user/\(user)/bin", "/run/current-system/sw/bin", "/nix/var/nix/profiles/default/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    let existing = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
    var seen = Set<String>()
    return (existing + extra).filter { seen.insert($0).inserted }.joined(separator: ":")
}
