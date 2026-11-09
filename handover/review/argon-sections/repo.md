# Argon Scoped Audit: Repository State, File Watching & Session Lifecycle (`argon-repo`)

Scope: `Sources/SextantApp/Repository.swift`, `FileWatcher.swift`, `RepoWindowController.swift`, `ReviewSummary.swift`, `SubjectPicker.swift`, `RevisionSheet.swift` (following calls into `Panes.swift`, `WindowActions.swift`, `JumpActions.swift`, `Document.swift`, `Reader.swift`, `ReviewStore.swift`, `Notes.swift`, `Titlebar.swift`, `ReviewHeader.swift`, `main.swift`, and `SextantCore`).

All microbenchmarks and adversarial reproduction tests were compiled in release mode against the real `SextantCore` and `FileWatcher.swift` sources plus exact extracts of the `SextantApp` methods under audit in `/Users/shrik450/Developer/review-ui/scratch/review/argon-sections/repo/`.
To rerun all benchmarks and adversarial tests:

```bash
cd /Users/shrik450/Developer/review-ui/scratch/review/argon-sections/repo && nix develop /Users/shrik450/Developer/review-ui -c swift build -c release && ./.build/release/RepoAuditBench
```

---

## 1. Architecture Audit

### Ownership and Data Flow
- **`Repository` (`Repository.swift:9-252`)**: `@MainActor` per-window owner of repository-wide state:
  - Owns `git: Git` (rooted at `commonDir`), `commonDir: URL`, `reviews: ReviewStore`, `notes: NotesStore`, `analysis: ContentAnalysis`, and `definitions: DefinitionIndex`.
  - Holds mutable snapshots of ref and status metadata: `worktrees: [Worktree]`, `branches: [Branch]`, `stashes: [Stash]`, `defaultBase: String?`, `pullRequests: [PullRequest]?`, `uncommitted: [String: Int]` (keyed by `w.root.path`), and `conflicts: [String: Set<String>]` (keyed by `w.root.path`).
  - Provides `nonisolated static` entry points (`readRefs`, `open`, `review(for:...)`, `base(for:...)`) so `AppDelegate.openRepo` (`main.swift:92`) can start git subprocesses before `RepoWindowController` finishes initializing.
- **`FileWatcher` (`FileWatcher.swift:6-29`)**: `@MainActor` wrapper over a CoreServices `FSEventStreamRef` configured with `kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer` on `DispatchQueue.main`, delivering `[String]` path batches to its closure.
- **`RepoWindowController` (`RepoWindowController.swift:46-1085`, `WindowActions.swift`, `JumpActions.swift`)**: `@MainActor` `NSWindowController` that owns practically all session coordination, file loading, watcher management, pane management, and UI synchronization:
  - Owns `repository: Repository`, `look: any Look`, `frame: WindowFrame`, `navigator: Navigator`, `strip: PaneStrip`, `inspector: Inspector`, `panes: [Pane]`, `focusedPane: Int`, `watcher: FileWatcher?`, `refreshTask: Task<Void, Never>?`, `afterFrame: [String: Timer]`, `busy: Int`, and modals (`picker`, `sheet`, `jumpPanel`).
  - Drives the `Session` lifecycle (`start`, `select`, `load`, `apply`, `place`, `loadSnapshotFiles`, `open`, `readyFile`, `fileState`, `prepareNeighbors`, `present`, `showOverview`, `currentLocation`, `restore`, `refresh`, `filesystemChanged`).
- **`Session` & `Pane` (`Panes.swift:6-67`)**:
  - `Session` (`Panes.swift:6-34`) is a passive `@MainActor` property bag representing a loaded `Review`, shared by all `Pane`s viewing that `Review` (`RepoWindowController.sessions`, `:201-204`). Holds `review`, `resolved`, `changes: [FileState]`, `snapshotFiles: [String]`, `snapshotLoaded: Snapshot?`, `explored: [String: FileState]`, `commitDetail`, `lastDiffs`, `lastKey`, `loadGeneration`, `isLoading`, `error`, `definitions`, `indexing`, `indexTask`, and `pickerIfEmpty`.
  - `Pane` (`Panes.swift:38-67`) pairs a `Reader` and `PaneSurface` with a `session: Session?`, `focus: Location.Place?`, `pendingLocation: Location?`, `showGeneration: Int`, and `loadingGeneration: Int?`.
- **`ReviewSummary` & `BaseChoices` (`ReviewSummary.swift:5-108`)**:
  - Value types computed on demand by `RepoWindowController.reviewSummary` (`:59-77`) on every `updateTitle()` call (`WindowActions.swift:56-60`) and pushed into `frame.show(reviewSummary)` (`ReviewHeader.show` in GlassLook or `ClassicFrame.show` -> `Titlebar.subject.show` + `StatusBar.show` in ClassicLook).
  - `BaseChoices.fill(_ button: NSPopUpButton)` (`:26-46`) rebuilds and attaches a fresh `NSMenu` of base branch choices to the header's `NSPopUpButton`.
- **`SubjectPicker` (`SubjectPicker.swift:6-369`)**:
  - `@MainActor` `NSViewController` presented in an `NSPopover` (`ReviewSummary.swift:92-108`). Filters `repository.worktrees`, `pullRequests`, `branches`, `stashes`, and async `git.searchCommits` results (`found: [Commit]`) into a flat `[Row]` array for an `NSTableView`.
- **`RevisionSheet` (`RevisionSheet.swift:7-91`)**:
  - `@MainActor` modal sheet (`NSPanel`) with an `NSComboBox` and async validation closure `resolve: (String) async -> String?`. Despite its name and default `"Go to Revision"` parameters, it is only instantiated by `RepoWindowController.goToLine` (`WindowActions.swift:415`).

### What Is in the Wrong Place or Duplicated
1. **`RepoWindowController` is a God controller mixing window/responder choreography with repository/session data loading**:
   - `Session` (`Panes.swift:6-34`) has zero methods; all of its state transitions (`load`, `apply`, `loadSnapshotFiles`, `fileState`, `prepareNeighbors`, `indexDefinitions`, `forgetDefinitions`) live as methods on `RepoWindowController`.
   - `FileWatcher` ownership and `.git` path filtering (`watch()`, `filesystemChanged()`, `refresh()` at `RepoWindowController.swift:208-216, 845-862`) live on `RepoWindowController` instead of `Repository`.
2. **`FileState` conflates session-level diff state, content-level whole-file/syntax state, and pane-level presentation state (`Document.swift:6-174`, `RepoWindowController.swift:306, 555-566, 633, 692-704`)**:
   - `Session.changes` holds `[FileState]`, shared across every `Pane` bound to that `Session`.
   - Yet `FileState` mutates `lines`, `isWhole`, `gapsBefore`, `tokens`, and `unfolded` in-place when any single pane calls `adoptWhole()` / `setWhole()` (`Document.swift:116-130, 169-174`). As proven in **Finding 1** below, opening a file from an Overview pane into a sibling pane corrupts the Overview pane's rendered rows in-place.
3. **Duplicate review resolution on launch (`Repository.swift:235-252` vs `RepoWindowController.swift:225-239, 283-291`)**:
   - When launched with a `spec`, `Repository.open` parses `spec` and calls `Repository.review(for: parsed, ...)` (`Repository.swift:238`), resolving the revision via `git`. Then `RepoWindowController.start` (`:233-234`) calls `await open(spec: spec, in: home)`, which re-parses `spec` and calls `try await repository.review(for: parsed, ...)` a second time before `load()` ever checks `preloaded`.
4. **Duplicate `git status` / diff / file listing across `Repository`, `Session`, and `DefinitionIndex`**:
   - `Repository.status(of:)` (`Repository.swift:147-159`) runs `git status --porcelain=v1 -z` directly in `SextantApp` and discards everything except total entry count and conflict paths, while `load()` runs `git diff` + `ls-files --others` (`Git.swift:178-179`), `loadSnapshotFiles` runs `git ls-files` + per-file `fileExists` stats (`Explore.swift:52-64`), and `indexDefinitions` runs `git ls-files -s -z` + `ls-files -m -o` (`Jump.swift:128-149`).
5. **Static unbounded caches in `ReviewStore.stores` (`ReviewStore.swift:10-18`) and `NotesStore.stores` (`Notes.swift:75-83`)**:
   - Both stores are retained forever in `private static var stores: [URL: ...]` dictionaries keyed by `commonDir.standardizedFileURL`, with no eviction when `RepoWindowController` closes.

### Unenforced Invariants
1. **Four incompatible path representations across `Repository`, `Resolver`, `FileWatcher`, and `RepoWindowController`**:
   - `Repository.worktrees` (from `git worktree list --porcelain -z`) and `Repository.uncommitted` / `conflicts` keys (`Repository.swift:120`) use POSIX `realpath` paths (e.g. `/private/var/...` with all symlinks resolved).
   - `FileWatcher` (`FileWatcher.swift:12`) passes `URL.resolvingSymlinksInPath().path` (which strips `/private` on macOS!), while FSEvents callbacks deliver `/private/var/...` realpath strings.
   - `Repository.commonDir` and `Subject.worktree(URL)` / `Resolver.resolve`'s `res.git.root` (`Review.swift:121`) preserve unresolved symlinks unless `Git.locate` happened to resolve them.
   - `Repository.worktree(at:)` and `ReviewStore.shared(for:)` use `.standardizedFileURL`, which resolves `..` but neither resolves symlinks nor normalizes `/private`.
   - Nothing enforces a single canonical path representation (see **Finding 3**).
2. **`Pane.focus` vs `Pane.reader.files` vs `Pane.showGeneration` / `loadingGeneration` (`Panes.swift:44-56`, `RepoWindowController.swift:364, 422, 519, 655, 678`)**:
   - Setting `p.focus = .file(path)` in `open()` (`:519`) happens before async file loading completes, while `p.reader.files` still holds the previous file.
   - Conversely, `showEmpty` paths (`:365, :423, :678`) set `p.focus = nil` without incrementing `p.showGeneration` or clearing `p.loadingGeneration` (see **Finding 4**).
3. **`RepoWindowController.busy` and `RepoWindowController.idleWaiters` (`RepoWindowController.swift:88-89, 588-609`)**:
   - `busy` is a non-atomic counter incremented/decremented across unstructured tasks and timers; `idleWaiters` is a process-wide `static var` shared across all windows, and `afterFrame` decrements `busy` before re-incrementing it during its retry loop (see **Finding 2**).
4. **`Session.review` identity mutation during `Resolver.resolve` (`Review.swift:134, 137, 169`, `RepoWindowController.swift:306, 357`)**:
   - `select(_:)` deduplicates sessions via `sessions.first { $0.review == r }` (`:306`), but `load(_:)` overwrites `s.review = res.review` (`:357`), where `Resolver.resolve` fills in `review.base` (for PRs), expands `review.subject = .commit(oid)` (for short SHAs/tags), or resets `review.scope = .everything`. Subsequent `select(r)` calls with the original un-normalized `Review` fail `s.review == r` and spawn duplicate `Session`s.

### How This Scope Fits the Plan's Target Design (`scratch/perf/plan.md`)
- **Step 1 (Confirmed bugs)**: Fix the newly identified bugs in this scope alongside the known ones:
  - Decouple per-pane view state (`isWhole`, `unfolded`, rendered line slice) from shared `Session.changes` so Overview and single-file panes don't corrupt each other (**Finding 1**).
  - Replace the 0-ms `afterFrame(..., waitingForFile: true)` spin-wait timer with direct completion-driven scheduling (**Finding 2**).
  - Canonicalize all repository, worktree, and watcher root URLs at construction using `Darwin.realpath` rather than `URL.resolvingSymlinksInPath()` (**Finding 3**).
  - Increment `p.showGeneration` and clear `p.loadingGeneration` on all empty/error transitions, and guard `currentLocation(of:)` against mid-load file mismatch (**Finding 4**).
  - Fix `SubjectPicker` remote-branch hiding when the query targets the remote prefix, and pass `checkout` instead of `home` as `here` (**Finding 6**).
  - Skip `oldLines`/`wholeFile` in `Repository.open` when the first diff is already whole or when `readerMode == "overview"` (**Finding 8**), and validate saved bases in `Resolver.resolve` (**Finding 9**).
- **Step 2 (Limits & lifetimes)**: Cancel `refreshTask`, `afterFrame` timers, `Session.indexTask`, `Reader.analysis`, and `SubjectPicker.searchTask` when their owning window/popover closes; evict `ReviewStore` and `NotesStore` when the last window for `commonDir` closes (**Finding 10**).
- **Step 3 (Cheap UI fast paths)**: Stop calling `updateTitle()` from `readerCurrentFileChanged`, `open()`, `present()`, and `showOverview()`; cache/guard `BaseChoices` menu construction so `NSMenu` is only rebuilt when branches or base change (**Finding 5**); replace `paths.contains` array scans with `Set(paths)` in `toggleReviewed`, `navigatorFileMenu`, and `validateMenuItem` (**Finding 7**); pre-split query words and short-circuit at the display limit in `SubjectPicker.rebuild()` (**Finding 6**); move `loadSnapshotFiles` sorting off the main actor (**Finding 7**).
- **Step 4 & Step 5 (Refresh coordinator & change fast paths)**: Move `FileWatcher` and refresh coordination into `Repository` (one in flight per worktree with an accumulated dirty set), preserve `FSEventStreamEventFlags` and event IDs, watch all worktrees (or mark hidden worktrees stale on switch), and update unchanged open files in place without re-running `present()` / wiping selection, `blame`, `explored`, and `definitions` (**Finding 8**).

---

## 2. Efficiency Summary

| Operation / Component | Current Work & Allocations | Complexity | Measured Cost / Waste |
| :--- | :--- | :--- | :--- |
| `afterFrame("navigator", waitingForFile: true)` (`RepoWindowController.swift:588-609`) | Schedules `Timer(timeInterval: 0)` on `RunLoop.main`; while `pane.isLoadingFile` is `true`, fires on every RunLoop turn, invalidates, decrements/increments `busy`, and allocates a new 0-ms `Timer` | $O(\text{load duration})$ busy-wait spin loop on `@MainActor` | **4,339 timer firings in 56 ms (~77,100 fires/sec)** on the main thread during a 50 ms file load; dips `busy` by 1 on every spin iteration. |
| `updateTitle()` -> `reviewSummary` -> `BaseChoices.fill` (`ReviewSummary.swift:26-77`, `WindowActions.swift:56-60`) | Filters `repository.branches` 3x; scans `changes.count(where: \.reviewed)`; allocates `Set` of all branch names; builds a fresh `NSMenu` and `NSMenuItem` for **every** local & remote branch (uncapped!) | $O(B + C)$ per call on `@MainActor` | **23.68 ms** and **10,005 `NSMenuItem`s** per call at $B=10\text{k}, C=10\text{k}$. Called on **every file crossed during overview scroll** (`50x = 1,184 ms`), **2x per file open**, and **4x per `toggleReviewed` with advance** (`94.7 ms`). |
| `SubjectPicker.rebuild()` & `matches()` (`SubjectPicker.swift:95-134`) | On every candidate branch/PR/stash/worktree, bridges `field.stringValue` from ObjC, trims, lowercases & splits `query`, joins & lowercases candidate strings; filters all $B$ branches before `.prefix(40/150)` | $O(B \cdot (|q| + |\text{text}|))$ on `@MainActor` per keystroke | **30.12 ms** at 10k branches and **154.88 ms** at 50k branches per keystroke; pre-splitting `query` + ASCII byte folding + early stop takes **3.16 ms** / **15.49 ms** (**9.5x–10.0x faster**). |
| `toggleReviewed` / `navigatorFileMenu` / `validateMenuItem` (`RepoWindowController.swift:881`, `WindowActions.swift:127, 442`) | `changes.indices.filter { paths.contains(changes[$0].path) }` using linear `Array.contains` over `paths: [String]` | $O(C \times P)$ string comparisons on `@MainActor` | **15.12 ms** ($C=5\text{k}, P=1\text{k}$) to **109.16 ms** ($C=10\text{k}, P=5\text{k}$) on main thread vs **0.28 ms** / **0.69 ms** with `Set(paths)` (**53x–159x faster**). |
| `loadSnapshotFiles` (`RepoWindowController.swift:441-458`) | Runs `files.sorted { $0.localizedStandardCompare($1) == .orderedAscending }` inside a `@MainActor` `Task`; calls `showFilesSoon()` twice on initial load | $O(N \log N)$ ICU locale comparisons on `@MainActor` | **18.81 ms** at 10k paths, **418.48 ms** main-thread stall at 100k paths (and ~1.4 s at 300k paths). |
| `apply()` on worktree refresh (`RepoWindowController.swift:386-416`) | Re-runs `place(p, here:)` -> `open()` -> `present()` on **every** pane even when the pane's focused file is unchanged (`previous[path]?.diff == d`); wipes `s.explored = [:]` and `forgetDefinitions(s)` | Full `NSTextStorage` rebuild + `git blame` + 3 `prepareNeighbors` tasks per refresh | Re-renders the open file, loses text selection, cancels Highlight Uses / Jump, re-reads explored files from disk, and cancels definition indexing on every background edit to any other file. |

---

## 3. Ranked Findings (Bugs, Slowness, Waste, Architecture)

*Note: Known findings already in `scratch/perf/plan.md` are omitted unless refined below with new root causes, failure modes, or benchmark measurements.*

---

### Finding 1 (Bug + Architecture — Critical): Opening a file beside `All Changes` mutates the shared `FileState` in-place, corrupting the Overview pane's lines, line numbers, syntax colors, and note references
- **Location**: `Sources/SextantApp/RepoWindowController.swift:306, 555-566, 633, 692-704`, `Sources/SextantApp/Document.swift:116-130, 169-174`, `Sources/SextantApp/Reader.swift:261, 333-337`
- **Category**: Bug + Architecture
- **Plan Step**: Step 1 (Confirmed bugs) & Step 3 (Cheap UI fast paths)
- **Evidence**:
  1. `RepoWindowController` shares a single `Session` instance across all panes viewing the same `Review` (`RepoWindowController.swift:306, 692-704`).
  2. When Pane 0 shows `All Changes` (`showOverview`, `:633`), `Reader.show(files: s.changes, overview: true)` calls `layoutRows` while each modified file `f = s.changes[k]` has `f.isWhole == false` and `f.lines` containing only its diff hunks (e.g., 4 lines around line 500, at indices `0..<4`). Pane 0's `CodeView.rows` stores `Row(kind: .line, file: k, line: 0..<4)`, and its `NSTextStorage` holds the rendered text of lines 500–502.
  3. When the user opens file `k` from the overview (`readerOpenFile` at `:692-704`, or via Command-click in the navigator at `:989`), `RepoWindowController` calls `branch()` to create Pane 1 sharing `s`, and calls `open(f.path, at: anchor)` in Pane 1.
  4. `open()` calls `fileState()` / `readyFile()` (`:555-566`), which calls `f.adoptWhole()` -> `f.setWhole(p.lines)` (`Document.swift:116-130, 169-174`) on the **shared `FileState` object `f`**.
  5. `f.setWhole` replaces `f.lines` in-place with all lines of the whole file (`1...600`), sets `f.isWhole = true`, clears `f.gapsBefore = [:]`, and resets `f.tokens = nil` — while **Pane 0 (still visible on screen beside Pane 1) is not reloaded and still holds `Row(kind: .line, file: k, line: 0..<4)`**!
  6. Immediately in Pane 0:
     - `f.lines[row.line]` now accesses lines 1–4 of the file (`.context`) instead of the hunk at line 500 (`.added`/`.deleted`).
     - When `recolor(file: k)` or `refreshReadState()` runs in Pane 0 (`CodeView.swift:326-346`), `f.lines[row.line].kind` is `.context`, stripping the green/red diff highlights from the hunk in Pane 0 and applying lines 1–4's syntax token ranges to lines 500–502's text.
     - `Gutter` in Pane 0 draws line numbers `1..4` beside lines `500..502`.
     - Clicking the hunk in Pane 0 to copy a reference (`copyReference`), add a note (`addNote`), or open at a line (`readerOpenFile`) calls `f.lineNumber(at: 2)` / `f.reference(...)`, which resolves to **line 3 (`// header line 3`)** instead of **line 501 (`let newVal = 2`)**!
     - Furthermore, `f.unfolded` (`Document.swift:26`) is stored on the shared `FileState`, so unfolding a section in one pane leaks into any other pane sharing `s`.
  - **Reproduction output from `RepoAuditBench` (`=== 4. Shared Session / FileState In-Place Mutation Bug ===`)**:
    ```text
    [Pane 0 Overview row at index 2]
      Before Pane 1 opens file: lineNo=501 kind=added text='    let newVal = 2'
      After Pane 1 opens file:  lineNo=3 kind=context text='// header line 3' (CORRUPTED in Pane 0!)
    ```
- **Fix**:
  - Never mutate `f.lines` from hunks-only to whole-file in-place while another `Reader` references `f`'s hunk indices.
  - Separate immutable hunk lines (`diff.hunks` / `hunkLines` + `hunkTokens`) from whole-file lines (`wholeLines` + `wholeTokens`) on `FileState` (or hold per-pane view state — whether the pane is rendering hunks or whole lines, and its `unfolded: Set<Int>` set — on `Reader`/`Pane`), so an Overview pane always indexes `hunkLines` (unless unfolded/showAll) while a single-file pane indexes `wholeLines`.

---

### Finding 2 (Slowness + Bug — High Impact): `afterFrame(..., waitingForFile: true)` spins in a 77,000-hz 0-ms `Timer` busy-wait loop on the main RunLoop while a file loads, and dips `busy` on every spin
- **Location**: `Sources/SextantApp/RepoWindowController.swift:588-609, 619-622, 444, 455`
- **Category**: Slowness + Waste + Bug
- **Plan Step**: Step 1 (Confirmed bugs) & Step 3 (Cheap UI fast paths)
- **Evidence**:
  Look at `RepoWindowController.afterFrame` (`RepoWindowController.swift:588-609`):
  ```swift
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
  ```
  1. **Tight 0-ms RunLoop spin loop on the main thread**:
     Whenever `apply()` runs (`:412-413`), it calls `loadSnapshotFiles` (which calls `showFilesSoon()` -> `afterFrame("navigator", waitingForFile: true)`) and then `place()` -> `open(...)`. Whenever the opened file is not already whole in memory (`readyFile == nil`), `open()` sets `p.loadingGeneration = gen` (`p.isLoadingFile == true`) and awaits `fileState(...)` on a background git/parse task.
     On the very next turn of `RunLoop.main`, the 0-second `Timer` fires, sees `self.pane.isLoadingFile == true`, clears `afterFrame["navigator"] = nil`, decrements `busy -= 1`, and immediately registers **another** `Timer(timeInterval: 0)` on `RunLoop.main`.
     For the entire time `fileState` is running in the background, the main thread is pinned in a tight 0-ms timer spin loop!
  2. **Premature `busy == 0` dip and `idleWaiters` firing**:
     Because line 597 executes `self.busy -= 1` *before* line 598 calls `self.afterFrame(...)` (which executes `busy += 1`), `busy` drops by 1 on every spin iteration. If `afterFrame` is the only remaining `busy` holder (for example, if `open()`'s `defer { busy -= 1; if p.loadingGeneration == gen { p.loadingGeneration = nil } }` hasn't cleared `loadingGeneration` or another `afterFrame` waiter is active), `busy` hits `0` and fires `RepoWindowController.idleWaiters` prematurely while `afterFrame` work still hasn't run.
  - **Benchmark numbers from `RepoAuditBench` (`=== 1. afterFrame(waitingForFile: true) 0-ms RunLoop Spin Loop ===`)**:
    ```text
    [50 ms file load] Timer fired 4339 times in 56.29 ms (77083 fires/sec on MainActor!), workRan=true
    [Premature idleWaiters] When afterFrame is the only busy holder, busy dips to 0 on spin and fires idleWaiters 148 times while still waiting!
    ```
- **Fix**:
  - Never poll `self.pane.isLoadingFile` with a recursive 0-ms `Timer`.
  - When `waitingForFile && self.pane.isLoadingFile`, store `work` in a pending callback dictionary (`pendingAfterFile[key] = work`, keeping `busy` incremented once without decrementing/re-incrementing) and trigger it directly when `open()` finishes (in `present()` or when `p.loadingGeneration` clears).

---

### Finding 3 (Bug — High Impact): `URL.resolvingSymlinksInPath()` strips `/private` on macOS while `FSEvents` and `git worktree list` preserve `/private`, breaking symlinked/temp worktree status lookups and causing self-refresh loops on `.git/sextant` writes
- **Location**: `Sources/SextantApp/FileWatcher.swift:12`, `Sources/SextantApp/Repository.swift:30-32, 51-54, 118-130`, `Sources/SextantCore/Review.swift:121`, `Sources/SextantApp/RepoWindowController.swift:268, 400, 469, 845-850`
- **Category**: Bug (Refines known canonical-roots finding in `plan.md` Step 4 with a critical macOS Foundation trap)
- **Plan Step**: Step 1 (Confirmed bugs) & Step 4 (Refresh coordinator)
- **Evidence**:
  `plan.md` notes that `FileWatcher` and `Repository` canonicalize roots differently, and earlier reviews suggested canonicalizing all roots with `URL.resolvingSymlinksInPath()`. **Testing on macOS proves `URL.resolvingSymlinksInPath()` is broken for matching `FSEvents` and `git` paths**:
  1. In macOS Foundation, `URL.resolvingSymlinksInPath()` calls `_NSStandardizePathUsingCache`, which resolves leaf symlinks (`sym/repo -> real/repo`) but **explicitly strips `/private` from `/private/var`, `/private/tmp`, and `/private/etc`**, returning `/var/folders/.../real/repo`.
  2. Conversely, `URL.resourceValues(forKeys: [.canonicalPathKey])` resolves `/var -> /private/var`, but **does not resolve leaf symlinks** (`sym/repo`), returning `/private/var/folders/.../sym/repo`.
  3. Meanwhile, both **CoreServices `FSEvents`** (`FileWatcher`) and **`git worktree list --porcelain -z` / `git rev-parse --show-toplevel`** call POSIX `realpath()`, returning `/private/var/folders/.../real/repo`.
  4. As a result, when a repository is opened via any symlinked path (or under `/tmp` / `/var`):
     - `Repository.refreshStatus()` (`Repository.swift:120`) keys `uncommitted` and `conflicts` by `w.root.path` from `git worktree list` (`/private/.../real/repo`), while `Resolver.resolve` (`Review.swift:121`) sets `res.git = Git(root: root)` (`/var/.../sym/repo`). Lookups `repository.uncommitted[res.git.root.path]` (`RepoWindowController.swift:469`) and `repository.conflicts[res.git.root.path]` (`:268, :400`) return **`nil` (0 uncommitted files, 0 conflicts)** — and would *still* return `nil` if canonicalized with `resolvingSymlinksInPath()`!
     - In `RepoWindowController.filesystemChanged` (`:846-848`), `common = repository.commonDir.path` is `/var/.../sym/repo/.git`, while `FSEvents` delivers `/private/var/.../real/repo/.git/sextant/reviewed.json`. `p.hasPrefix(common + "/sextant")` evaluates to **`false`** (and would *still* evaluate to `false` with `commonDir.resolvingSymlinksInPath().path`!), so **every write Sextant makes to `.git/sextant/` (`reviewed.json`, `read.json`, `notes.json`, `definitions.json`) triggers `refresh()`**!
  - **Reproduction output from `RepoAuditBench` (`=== 5. Symlinked Worktree & CommonDir Mismatch ===`)**:
    ```text
    git.worktrees()[0].root.path:                 /private/var/folders/.../real/repo
    resolved.git.root.path:                       /var/folders/.../sym/repo
    resolved.git.root.resolvingSymlinksInPath():  /var/folders/.../real/repo
    resolved.git.root (.canonicalPathKey):        /private/var/folders/.../sym/repo
    Darwin.realpath(resolved.git.root.path):      /private/var/folders/.../real/repo
    uncommitted[resolved.git.root.path]:          nil (BUG: nil!)
    uncommitted[resolvingSymlinksInPath()]:       nil (BUG: STILL nil because resolvingSymlinksInPath strips /private!)
    uncommitted[.canonicalPathKey]:               nil (BUG: STILL nil because .canonicalPathKey doesn't resolve leaf symlink!)
    uncommitted[Darwin.realpath]:                 Optional(1) (MATCHES git & FSEvents!)
    Real FSEvents delivered path:                 /private/var/folders/.../real/repo/.git/sextant
    Has prefix repository.commonDir.path?:        false (FALSE!)
    Has prefix commonDir.resolvingSymlinks()?:    false (FALSE! resolvingSymlinksInPath strips /private, while FSEvents includes /private!)
    Has prefix Darwin.realpath(commonDir)?:       true (TRUE!)
    ```
- **Fix**:
  - Define a single `canonicalFileURL` helper in `SextantCore` backed by POSIX `Darwin.realpath` (falling back to `standardizedFileURL` only if the path does not exist yet on disk).
  - Canonicalize `Git.Location.root`, `Git.Location.commonDir`, `Worktree.root`, `Subject.worktree(root)`, and `FileWatcher` input paths with `Darwin.realpath` so all path strings in `Repository`, `Resolver`, `FileWatcher`, and `RepoWindowController` are byte-for-byte identical to `FSEvents` and `git`.
  - Also filter `<commonDir>/worktrees/<id>/logs/` in `filesystemChanged` (`RepoWindowController.swift:847`), since linked-worktree reflogs live under `commonDir/worktrees/<id>/logs/`, not `commonDir/logs/`.

---

### Finding 4 (Bug — High Impact): Uncancelled file loads overwrite Empty/Error states (`showEmpty`), and refreshes during an in-flight file open clobber the new file's scroll position with the previous file's line number
- **Location**: `Sources/SextantApp/RepoWindowController.swift:364-367, 422-431, 518-551, 655-686`
- **Category**: Bug (Concurrency / State Synchronization)
- **Plan Step**: Step 1 (Confirmed bugs) & Step 4 (Refresh coordinator)
- **Evidence**:
  Two state-synchronization races exist in `RepoWindowController`'s `Pane` navigation lifecycle:
  1. **`showEmpty` transitions never increment `p.showGeneration` or clear `p.loadingGeneration` (`RepoWindowController.swift:364-367, 422-431, 677-680`)**:
     When `open(_ path: String, ...)` (`:518-551`) starts loading a file that isn't ready yet, it increments `p.showGeneration += 1`, sets `let gen = p.showGeneration`, sets `p.loadingGeneration = gen`, and spawns an unstructured `Task` to await `fileState(path, in: t, of: s)`.
     If, before `fileState` returns, a refresh completes with 0 changes (`place` at `:422-431` or `restore` at `:677-680`) or an error (`load` catch at `:364-367`), `RepoWindowController` sets `p.focus = nil` and calls `p.reader.showEmpty(...)` **without incrementing `p.showGeneration` or clearing `p.loadingGeneration`**.
     When the in-flight `fileState` task finishes milliseconds later (`:542`), `guard gen == p.showGeneration` **still succeeds**, so line 548 calls `present(f, at: anchor, in: p)` — replacing the empty/error state with the stale file while `p.focus` remains `nil`!
  2. **`currentLocation(of:)` reads the old file's scroll position when a new file is mid-load (`RepoWindowController.swift:519, 655-670`)**:
     In `open(newPath, at: .firstChange, in: p)` (`:519`), `p.focus = .file(newPath)` is set synchronously at the start of `open`, while `p.reader.files` still contains `[oldFile]` until `await fileState(...)` finishes and calls `present()`.
     If a refresh runs `apply()` (`:395`) while `newPath` is loading:
     ```swift
     let top = side(reader.topPosition)
     let caret = side(reader.caret).map { Location.Caret(path: $0.path, line: $0.line, column: reader.caretColumn) }
     switch focus {
     case .overview: return Location(review: r, place: .overview(path: top?.path), top: top?.line ?? SideLine(number: 1, old: false), caret: caret)
     case .file(let path): return Location(review: r, place: .file(path), top: top?.line ?? SideLine(number: 1, old: false), caret: caret)
     }
     ```
     `focus` is `.file(newPath)`, while `top` is `(path: oldPath, line: SideLine(number: 450, old: false))` from `p.reader.files[0]` (`oldFile`)!
     Line 668 ignores `top?.path != path` and constructs `Location(review: r, place: .file(newPath), top: line 450, ...)`. `apply()` then calls `place` -> `restore` -> `open(newPath, at: .restore(top: line 450, ...))`, losing the requested `.firstChange` anchor and scrolling `newPath` to `oldPath`'s line 450!
- **Fix**:
  - Increment `p.showGeneration += 1` and set `p.loadingGeneration = nil` whenever `p.reader.showEmpty(...)` is called (`:365, :423, :678`).
  - Record `p.loadingAnchor: Anchor?` on `Pane` while `p.isLoadingFile` is true, and in `currentLocation(of:)` verify `top?.path == path` (or preserve the in-flight `(path, loadingAnchor)` instead of reading `reader.topPosition` from the previous file).

---

### Finding 5 (Slowness + Waste — High Impact): `updateTitle()` is called on every file boundary during overview scrolling and 2x–4x per file action, rebuilding an uncapped `NSMenu` of all local and remote branches on the main thread (23.7 ms/call, 1.18 s per 50-file scroll at 10k branches)
- **Location**: `Sources/SextantApp/ReviewSummary.swift:26-46, 56-77`, `Sources/SextantApp/WindowActions.swift:56-60`, `Sources/SextantApp/RepoWindowController.swift:525, 623, 651, 720, 864-894`
- **Category**: Slowness + Waste
- **Plan Step**: Step 3 (Cheap UI fast paths)
- **Evidence**:
  1. **Unnecessary calls where `ReviewSummary` cannot change**:
     `ReviewSummary` depends only on `repository.name`, `review`, `resolved`, `commitDetail`, `repository.branches/worktrees/stashes/pullRequests/defaultBase`, `changes.count`, and `changes.count(where: \.reviewed)`. It does **not** depend on which file is focused or visible.
     Yet `updateTitle()` is called in:
     - `readerCurrentFileChanged(_:)` (`RepoWindowController.swift:720`) — which fires **every time scrolling in `All Changes` (`overview`) crosses a file boundary**!
     - Both `open()` (`:525`) AND `present()` (`:623`) — firing **twice** every time the user steps to the next/previous file!
     - Four times in a single `toggleReviewed(..., advance: true)` action (`:879-894`): once in `reviewsChanged` (`:872`), once in `open` (`:525`), once in `present` (`:623`), and once at the end of `toggleReviewed` (`:893`).
  2. **Uncapped $O(B + C)$ main-thread work per `updateTitle()` call (`ReviewSummary.swift:26-46, 56-77`)**:
     Every `updateTitle()` call:
     - Scans `changes.count(where: \.reviewed)` ($O(C)$).
     - Filters `repository.branches` 3 times (`filter { $0.name != own }`, `filter { !$0.isRemote }.map(\.name)`, `filter(\.isRemote).map(\.name)`).
     - Calls `BaseChoices.fill(_ button: NSPopUpButton)` (`:26-46`), which allocates a `Set` of all branch names, creates a brand-new `NSMenu()`, instantiates an `NSMenuItem` for **every local and remote branch in the repository** (with no cap, unlike `SubjectPicker`'s 40/150 cap), assigns `button.menu = menu` (which also clobbers the popup menu if the user currently has it open during an agent refresh!), and linearly scans `menu.items`.
  - **Benchmark numbers from `RepoAuditBench` (`=== 2. ReviewSummary + BaseChoices.fill Scaling ===`)**:
    - 100 branches, 100 changes: **0.15 ms** / call (105 `NSMenuItem`s) | 50-file overview scroll: **7.3 ms**
    - 1,000 branches, 1,000 changes: **1.34 ms** / call (1,005 `NSMenuItem`s) | 50-file overview scroll: **66.9 ms**
    - 5,000 branches, 5,000 changes: **9.30 ms** / call (5,005 `NSMenuItem`s) | 50-file overview scroll: **464.8 ms**
    - 10,000 branches, 10,000 changes: **23.68 ms** / call (10,005 `NSMenuItem`s) | 50-file overview scroll: **1,183.9 ms** | 1 `toggleReviewed`+advance (4x): **94.7 ms**
- **Fix**:
  - Remove `updateTitle()` from `readerCurrentFileChanged`, `open()`, `present()`, and `showOverview()` (pane headers already update their own file titles via `Reader.updateHeader()`).
  - Make `ReviewSummary` and `BaseChoices` `Equatable`; in `ReviewHeader.show` and `SubjectControl.show`, only call `choices?.fill(base)` when `choices != lastChoices`, and populate the `NSMenu` lazily in `NSMenuDelegate.menuNeedsUpdate(_:)` (capped to e.g. 200 branches).

---

### Finding 6 (Slowness + Bug — High Impact): `SubjectPicker.rebuild()` re-splits the query and joins/lowercases strings for every branch on the main thread (30 ms at 10k, 155 ms at 50k branches), suppresses matching remote branches when local shares the OID, and resolves `staged`/`uncommitted` against `home` instead of the active worktree
- **Location**: `Sources/SextantApp/SubjectPicker.swift:86-134, 178-209`, `Sources/SextantApp/ReviewSummary.swift:94`
- **Category**: Slowness + Bug + Waste
- **Plan Step**: Step 1 (Confirmed bugs) & Step 3 (Cheap UI fast paths)
- **Evidence**:
  1. **Per-candidate query bridging, splitting, and string joining (`SubjectPicker.swift:95-99, 121-125`)**:
     ```swift
     private var query: String { field.stringValue.trimmingCharacters(in: .whitespaces) }

     private func matches(_ texts: String...) -> Bool {
         let words = query.lowercased().split(separator: " ")
         let hay = texts.joined(separator: " ").lowercased()
         return words.allSatisfy { hay.contains($0) }
     }
     ```
     Inside `rebuild()`, `matches(...)` is called for every candidate worktree, PR, branch, and stash. On **every candidate**, `matches()` bridges `field.stringValue` from Objective-C `NSControl`, trims whitespace, lowercases `query`, splits `query` on `" "`, allocates `texts.joined(separator: " ")`, and allocates `.lowercased()`. Furthermore, `branches.filter { ... }.prefix(q.isEmpty ? 40 : 150)` filters **all** $B$ branches in the repository before taking the first 40 or 150, even though `repository.branches` is already sorted by `-committerdate`.
     - **Benchmark numbers from `RepoAuditBench` (`=== 3. SubjectPicker.rebuild() Scaling ===`)**:
       - 1,000 branches: `q=""` **0.16 ms** current vs **0.03 ms** optimized (**5.9x**); `q="feature auth 99999"` **2.90 ms** current vs **0.34 ms** optimized (**8.6x**)
       - 10,000 branches: `q=""` **1.67 ms** current vs **0.26 ms** optimized (**6.4x**); `q="feature auth 99999"` **30.12 ms** current vs **3.16 ms** optimized (**9.5x**)
       - 50,000 branches: `q=""` **8.50 ms** current vs **1.36 ms** optimized (**6.3x**); `q="feature auth 99999"` **154.88 ms** current vs **15.49 ms** optimized (**10.0x**)
  2. **Remote branch deduplication bug hides remote branches when searching by remote prefix (`SubjectPicker.swift:121-124`)**:
     ```swift
     let locals = Dictionary(repository.branches.filter { !$0.isRemote }.map { ($0.name, $0.oid) }, uniquingKeysWith: { a, _ in a })
     let branches = repository.branches.filter { b in
         if b.isRemote, let slash = b.name.firstIndex(of: "/"), locals[String(b.name[b.name.index(after: slash)...])] == b.oid { return false }
         return q.isEmpty || matches(b.name, b.subject)
     }
     ```
     Because `locals[...] == b.oid` drops `origin/feature/login` **before** checking whether local `feature/login` matched `q`, typing `"origin/feature"` or `"origin/"` in `SubjectPicker` when `feature/login` is in sync with `origin/feature/login` returns **0 branches** (`[]`), hiding both the local branch (which doesn't match `"origin/"`) and the remote branch!
     - **Reproduction output from `RepoAuditBench`**:
       ```text
       [Adversarial Test - SubjectPicker query='origin/feature' when local 'feature/login' shares OID]
         Current branches returned:   [] (count=0 -- BUG: hides remote even though local didn't match query!)
         Optimized branches returned: ["origin/feature/login"] (count=1)
       ```
  3. **Wrong worktree passed as `here` to `SubjectPicker` (`ReviewSummary.swift:94`)**:
     `SubjectPicker.init`'s doc comment (`SubjectPicker.swift:31`) states `- Parameter here: The checkout being read, which typed staged or uncommitted refer to.`
     However, `RepoWindowController.showPicker` (`ReviewSummary.swift:94`) passes `here: home` (the checkout the window was initially opened from) instead of `here: checkout` (`WindowActions.swift:165`, the checkout of the focused pane's review). If a user switches to linked worktree `W2` and types `staged` or `uncommitted` in `SubjectPicker`, it opens `W1` (`home`) instead of `W2`!
  4. **Uncancelled `searchTask` and redundant `loadPullRequests` on popover open/close (`SubjectPicker.swift:86-93, 178-190`)**:
     `viewDidAppear` unconditionally spawns `Task { await repository.loadPullRequests(); rebuild() }` every time the popover opens, and `SubjectPicker` never cancels `searchTask` in `viewWillDisappear()`.
- **Fix**:
  - Precompute lowercased query tokens once per `rebuild()`, match without string joining, only deduplicate a remote branch `origin/X` when local `X` shares `b.oid` **and** `X` itself matched the query, and stop iterating once `40` (or `150`) branch matches are collected.
  - Pass `here: checkout` in `RepoWindowController.showPicker` (`ReviewSummary.swift:94`).
  - Cancel `searchTask` in `viewWillDisappear()`.

---

### Finding 7 (Slowness — High Impact): `toggleReviewed`, `navigatorFileMenu`, and `validateMenuItem` run $O(C \times P)$ linear `Array.contains` scans on the main thread (109 ms stall), and `loadSnapshotFiles` runs `localizedStandardCompare` on `@MainActor` (418 ms stall at 100k paths)
- **Location**: `Sources/SextantApp/RepoWindowController.swift:451, 881`, `Sources/SextantApp/WindowActions.swift:127, 442`
- **Category**: Slowness
- **Plan Step**: Step 3 (Cheap UI fast paths)
- **Evidence**:
  1. **$O(|changes| \times |paths|)$ `Array.contains` in 3 main-thread methods**:
     - `RepoWindowController.toggleReviewed` (`RepoWindowController.swift:881`): `let idx = changes.indices.filter { paths.contains(changes[$0].path) }`
     - `RepoWindowController.navigatorFileMenu` (`WindowActions.swift:127`): `let files = changes.filter { paths.contains($0.path) }`
     - `RepoWindowController.validateMenuItem` (`WindowActions.swift:442`): `let files = changes.filter { paths.contains($0.path) }` (which also runs when opening `Go to Anything` via `enabledCommands` at `JumpActions.swift:114`!).
     When the user selects a top-level directory or multi-selects $P$ files in the navigator and right-clicks, opens a menu, presses `⌘K`, or presses `⇧R`, `paths.contains(...)` scans `paths` linearly for each of the $C$ changes.
     - **Benchmark numbers from `RepoAuditBench` (`=== 6. RepoWindowController Scaling Curves ===`)**:
       - $C = 1\text{k}, P = 100$: **0.31 ms** `Array.contains` vs **0.05 ms** `Set` (**6.5x speedup**)
       - $C = 5\text{k}, P = 1\text{k}$: **15.12 ms** `Array.contains` vs **0.28 ms** `Set` (**53.1x speedup**)
       - $C = 10\text{k}, P = 5\text{k}$: **109.16 ms** `Array.contains` vs **0.69 ms** `Set` (**158.9x speedup**)
  2. **`loadSnapshotFiles` sorts on `@MainActor` without a generation check (`RepoWindowController.swift:441-458`)**:
     ```swift
     Task {
         defer { busy -= 1 }
         let files = ((try? await git.files(in: snapshot)) ?? []).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
         guard s.target?.snapshot == snapshot else { return }
     ```
     Because `Task { ... }` inherits `@MainActor` isolation from `RepoWindowController`, `.sorted { $0.localizedStandardCompare($1) == .orderedAscending }` executes synchronously on the **main thread** after `await git.files(in: snapshot)` returns:
     - 1,000 paths: **3.32 ms** on `@MainActor`
     - 10,000 paths: **18.81 ms** on `@MainActor`
     - 100,000 paths: **418.48 ms** on `@MainActor`
     In addition, `guard s.target?.snapshot == snapshot` only checks `.worktree == .worktree`, not a generation counter, so overlapping `loadSnapshotFiles(s, force: true)` tasks from refreshes can complete out of order and overwrite newer file lists.
- **Fix**:
  - Convert `paths` to `let pathSet = Set(paths)` before filtering `changes` in `toggleReviewed`, `navigatorFileMenu`, and `validateMenuItem`.
  - Sort snapshot files off the main actor using UTF-8 byte order (or keep git's already-sorted output from `ls-files` / `ls-tree`) and guard publication with a generation counter on `Session`.

---

### Finding 8 (Waste + Bug — High Impact): Every worktree refresh where *any* file changed forces a full reload of unchanged open files (wiping selection, `blame`, `usesWord`, `explored`, and `definitions`), while `Repository.open` wastes a blob read and doubles lines when the first file is added
- **Location**: `Sources/SextantApp/RepoWindowController.swift:386-416, 608-624`, `Sources/SextantApp/Repository.swift:247-249`, `Sources/SextantApp/WindowActions.swift:413-421`, `RepoWindowController.swift:987-995`
- **Category**: Waste + Bug
- **Plan Step**: Step 1 (Confirmed bugs), Step 3 (Cheap UI fast paths) & Step 4 (Refresh coordinator)
- **Evidence**:
  1. **Unchanged open files are completely reloaded on every refresh when any other file in the review changes (`RepoWindowController.swift:395-413`)**:
     When an agent modifies `a.swift` in the background while the user is reading `b.swift`:
     - `apply()` reuses `b.swift`'s `FileState` (`previous["b.swift"].flatMap { $0.diff == d ? $0 : nil }` at `:401`), **but** line 413 unconditionally calls `for p in showing { place(p, here: heres[ObjectIdentifier(p)]) }` -> `restore()` -> `open("b.swift", at: .restore(...))` -> `present(f, ...)`!
     - `present()` (`:608-624`) sets `reader.blame = nil` (and re-runs `git blame` for `b.swift`), calls `reader.show(files: [f], overview: false)` (which wipes `usesWord = nil`, `boxed = nil`, cancels in-file `jump`, rebuilds the entire `NSAttributedString`, and replaces the user's text selection range with a single caret position), and `open()` spawns 3 new `prepareNeighbors` tasks for `b.swift`!
     - Meanwhile, lines 407-410 (`if keepPosition, res.target.snapshot == .worktree { s.explored = [:]; forgetDefinitions(s) }`) wipe **all** explored files `s.explored` (forcing any pane viewing an unchanged explored file to re-read it from disk and re-parse it from scratch) and cancel/wipe `s.definitions` on every single edit!
     - Conversely, when `res.target.snapshot == .index` (`Scope.staged`), lines 407-410 **never** invalidate `s.explored` or `s.definitions` when files are staged with `git add`!
  2. **`goToLine` (`WindowActions.swift:417`) and `navigatorOpen` (`RepoWindowController.swift:987-995`)**:
     - `goToLine` calls `self.open(f.path, at: .line(...))` on the already-focused file `f`, triggering `present()` which rebuilds the entire `NSTextStorage`, wipes `blame` and `usesWord`, and spawns `prepareNeighbors` just to scroll to a line (unlike `JumpActions.swift:100` which calls `reader.land(onLine: i)`).
     - `navigatorOpen(path: String, line: Int?)` (`:991`) has `else if focus == .file(path) { return }`, which **ignores the `line` argument completely** when the file is already focused!
  3. **`Repository.open` (`Repository.swift:247-249`) reads `oldLines` and runs `wholeFile` even when `diffs.first` is an added/deleted file or when `readerMode == "overview"`**:
     ```swift
     if let first = diffs.first, !first.isBinary, let old = try? await resolved.git.oldLines(of: first) {
         firstWhole = wholeFile(first.hunks, oldLines: old)
     }
     ```
     When `first` is an added or untracked file (`oldOid == zeroOid`), `FileState.init` (`Document.swift:56`) already sets `isWhole = true` from the hunk. Yet `Repository.open` calls `oldLines(of: first)` (which reads the new blob/worktree file because `oldOid == zeroOid`) and `wholeFile(first.hunks, oldLines: old)`, producing a doubled `[DiffLine]` array (`6` lines for a `3`-line file in `RepoAuditBench` Section 5). If `first.notes.isEmpty`, `offerWhole` (`Document.swift:165`) silently discards `firstWhole` after wasting the launch I/O and allocation; if `first.notes` is non-empty, `offerWhole` keeps it and corrupts the first file with doubled lines!
- **Fix**:
  - In `apply()`, if a pane `p` is showing `.file(path)` where the `FileState` instance `f` is identical (`f === p.reader.files.first`) and `p.pendingLocation == nil`, do **not** call `place(p, here:)` / `present()`; leave the reader untouched.
  - Only evict entries from `s.explored` whose path was in the changed path set (or whose index blob OID changed when `snapshot == .index`), and update `s.definitions` incrementally per changed path instead of calling `forgetDefinitions(s)`.
  - In `goToLine` and `navigatorOpen`, if `focus == .file(path), let f = focusedFile, let i = f.index(ofLine: line)`, call `reader.land(onLine: i)` directly.
  - In `Repository.open` (`Repository.swift:247`), skip `oldLines`/`wholeFile` when `first.change.isAdded || first.change.isDeleted || first.hunks.isEmpty` or when `readerMode == "overview" && diffs.count > 1`.

---

### Finding 9 (Bug — Medium Impact): Deleted or stale saved base branches in `UserDefaults` cause `Resolver.resolve` to silently show only the tip commit (for branches) or hide all branch commits (for worktrees) while displaying the deleted base name
- **Location**: `Sources/SextantApp/Repository.swift:163-180, 197-205`, `Sources/SextantCore/Review.swift:156-168`
- **Category**: Bug
- **Plan Step**: Step 1 (Confirmed bugs) & Step 4 (Refresh coordinator)
- **Evidence**:
  1. `Repository.remember(base:for:usual:)` (`Repository.swift:172-176`) persists custom base branch choices in `UserDefaults.standard` under `"bases"`.
  2. When that base branch (e.g., an earlier stacked PR branch `feature-part-1`) is later deleted after merge, `Repository.base(for: subject)` (`:166-169`) still returns `"feature-part-1"`.
  3. In `Resolver.resolve` (`Review.swift:156-166`):
     ```swift
     var mergeBase: String?
     if review.subject.hasBase, let base = review.base, let head {
         mergeBase = await git.mergeBase(base, head)
     }
     ...
     let everything: Target = switch review.subject {
     case .worktree: .worktree(since: mergeBase)
     case .commit(let c): .commit(c)
     default: head.map { h in mergeBase.map { .range(base: $0, head: h) } ?? .commit(h) } ?? .worktree(since: nil)
     }
     ```
     Because `git.mergeBase("feature-part-1", head)` fails and returns `nil`:
     - For `.branch("my-branch")`: `everything` silently falls back to `.commit(head)` — diffing **only the single tip commit** of `my-branch` while `res.review.base` remains `"feature-part-1"` and the UI header claims `Compared with feature-part-1`!
     - For `.worktree(root)`: `everything` falls back to `.worktree(since: nil)` and `commits` is `[]`, hiding all commits on the branch and the `"All Work"` scope row while claiming `Compared with feature-part-1`!
  - **Reproduction output from `RepoAuditBench` (`=== 5. Symlinked Worktree & CommonDir Mismatch ===`)**:
    ```text
    [Deleted saved base 'deleted-base-branch' on .branch('main')]: resolved.mergeBase=nil, resolved.target=commit("c559056f7a989134215110ed204f0784e0412a0a") (silently falls back to single tip commit while UI still says 'Compared with deleted-base-branch'!)
    ```
  4. Also in `Repository.review(for: .revision(r), ...)` (`Repository.swift:197-205`):
     If the user types `"refs/heads/main"` or `"refs/remotes/origin/main"` (which `SubjectPicker.looksLikeRevision` at `SubjectPicker.swift:139` explicitly recognizes via `s.hasPrefix("refs/")`), `refs.branches.first { $0.name == r }` fails to match because `Branch.name` stripped `"refs/heads/"` / `"refs/remotes/"`. It then falls through to `git.resolve(r)` and opens `.commit(oid)` instead of `.branch("main")`!
- **Fix**:
  - In `Repository.base(for:usual:commonDir:)` / `Resolver.resolve`, if a saved base from `UserDefaults` is not present in `refs.branches` and `await git.resolve(base) == nil`, clear the stale saved entry and fall back to `usual` (`defaultBase`).
  - In `Repository.review(for: .revision(r), ...)`, strip `"refs/heads/"` or `"refs/remotes/"` before matching `refs.branches`.

---

### Finding 10 (Bug + Memory Retention — Medium Impact): Closing a window or sheet leaves tasks, timers, and static stores alive, and `RevisionSheet.submit()` allows concurrent re-entry on Return
- **Location**: `Sources/SextantApp/RepoWindowController.swift:88-89, 588, 843, 928-932`, `Sources/SextantApp/ReviewStore.swift:10-18`, `Sources/SextantApp/Notes.swift:75-83`, `Sources/SextantApp/RevisionSheet.swift:66-80`
- **Category**: Bug + Memory Retention
- **Plan Step**: Step 2 (Limits and lifetimes)
- **Evidence**:
  1. **`RepoWindowController.windowWillClose` (`RepoWindowController.swift:928-932`)**:
     ```swift
     func windowWillClose(_ notification: Notification) {
         watcher = nil
         picker?.close()
         (NSApp.delegate as? AppDelegate)?.windowClosed(self)
     }
     ```
     When a repository window closes:
     - `refreshTask?.cancel()` is not called (`refreshTask` retains `self` until sleep + `repository.refresh()` completes).
     - `afterFrame` timers (`:588`) are not invalidated.
     - `s.indexTask?.cancel()` on each `s in sessions` (`JumpActions.swift:28`) is not called, so background definition indexing keeps spawning `git` and parsing files for a closed window.
     - `p.reader` analysis tasks (`Reader.analysis`, `Reader.swift:196`) are not cancelled (and `discard(_ closed: [Pane])` at `RepoWindowController.swift:766-771` when closing a pane also never cancels `p.reader`'s active `analysis` task!).
     - `ReviewStore.stores` (`ReviewStore.swift:10`) and `NotesStore.stores` (`Notes.swift:75`) hold every opened repository's `ReviewStore` and `NotesStore` in `static var stores: [URL: ...]` dictionaries forever without eviction.
     - `RepoWindowController.idleWaiters` (`:89`) is a `static var` across all windows; if a window closes while `busy > 0`, waiters hang forever.
  2. **`RevisionSheet.submit()` (`RevisionSheet.swift:66-80`)**:
     `submit()` disables `go.isEnabled = false`, but leaves `field` (`NSComboBox`, whose `action` is also `#selector(submit)`) enabled. Pressing Return twice while `await resolve(spec)` is running spawns concurrent `resolve` tasks, and clicking `Cancel` (`dismiss`) does not cancel an in-flight `resolve` task before calling `finish(nil)`.
- **Fix**:
  - In `windowWillClose`, cancel `refreshTask`, invalidate all `afterFrame` timers, cancel `s.indexTask` for all sessions, call `discard(panes)` (and have `discard` cancel `p.reader`'s analysis task), and evict `ReviewStore` / `NotesStore` / `ObjectReader` when no remaining window references `commonDir`.
  - Move `idleWaiters` from a `static var` to an instance property on `RepoWindowController`.
  - In `RevisionSheet`, guard `submit()` against re-entry while a task is running, disable `field.isEnabled = false` alongside `go.isEnabled = false`, and cancel the task in `dismiss()`.

---

## 4. Correctness Edge Cases That a Performance Rewrite Could Break

1. **Path canonicalization on macOS (`/private/var`, `/private/tmp`, firmlinks, and symlinks)**:
   - As proven in **Finding 3**, `URL.resolvingSymlinksInPath()` strips `/private`, while `URL.resourceValues(forKeys: [.canonicalPathKey])` does not resolve leaf symlinks. Any watcher classifier or worktree lookup in Step 4 that uses either of those instead of `Darwin.realpath` will silently drop FSEvents or miss worktree status entries whenever a repository or worktree path traverses `/tmp`, `/var`, or a symlink.
2. **Coalesced FSEvents flags (`MustScanSubDirs`, `UserDropped`, `KernelDropped`, `RootChanged`, `HistoryDone`) and watcher recreation gaps**:
   - Currently `RepoWindowController.watch()` (`:208-216`) recreates `FileWatcher` with `kFSEventStreamEventIdSinceNow` whenever a pane switches into or out of a `.worktree` subject, dropping events during the transition. Step 4 must keep a single persistent stream across `commonDir` and all known worktrees, start watching *before* the initial status/ref read, and trigger a full subtree/worktree rescan whenever `(flags & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)) != 0`.
3. **Global vs per-worktree refresh invalidation (`RepoWindowController.swift:858-859`)**:
   - Currently `for s in sessions where changed || s.target?.includesIndex == true { load(s, keepPosition: true) }` reloads *every* session (even immutable `.commit(oid)` and `.stash(oid)` sessions!) whenever `repository.refresh()` returns `changed == true` (e.g., because an untracked file appeared in worktree `W2` or a remote branch moved). Conversely, if a worktree `W1` is viewing a specific commit scope (`.commits(newest, oldest)`), `s.target` is `.commit(oid)` (`includesIndex == false`), so changes to `uncommitted[W1]` must update the navigator's `scopeRows()` badge (`statusChanged()`) **without** re-diffing the immutable commit `oid`.
4. **Shared `Session` across Overview and single-file panes (`Finding 1`)**:
   - In Step 3 and Step 8 (per-block overview edits / lazy whole-blob loading), multiple panes can simultaneously view the same `Session` at different levels of detail (e.g., Pane 0 in hunks-only `All Changes` and Pane 1 in whole-file mode on `foo.swift`, or two panes with different unfolded ranges). `FileState` must never overwrite hunk line arrays or share `unfolded: Set<Int>` across panes.
5. **Scope-specific snapshot invalidation (` Snapshot.worktree` vs `Snapshot.index` vs `Snapshot.commit`)**:
   - When `s.target == .staged`, `s.target.snapshot` is `.index`. Currently `apply()` only invalidates `s.explored` and `s.definitions` when `res.target.snapshot == .worktree` (`:407`). Step 4/5's refresh coordinator must invalidate `.index`-snapshot sessions when `.git/index` changes, `.worktree`-snapshot sessions when working files or `.git/index` change, and `.commit(oid)` sessions **never** (except ref decorations if displayed).
6. **Multi-worktree `.git/worktrees/<id>/` metadata layout**:
   - In a linked worktree `W`, `HEAD`, `index`, `logs/HEAD`, and `rebase-merge`/`rebase-apply` live inside `<commonDir>/worktrees/<id>/`, **not** `<W>/.git/` (which is just a `gitdir:` text pointer file) and **not** directly under `<commonDir>/HEAD` or `<commonDir>/index`. Step 4's event classifier must map `<commonDir>/worktrees/<id>/index` and `<commonDir>/worktrees/<id>/HEAD` to worktree `<id>`, while ignoring `<commonDir>/worktrees/<id>/logs/` and `<commonDir>/sextant/`.
