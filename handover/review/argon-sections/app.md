# Argon Scoped Audit: App, Command Layer, Menus, Multi-Window & CLI (`argon-app`)

Scope: `Sources/SextantApp/main.swift`, `Sources/SextantApp/WindowActions.swift`, `Sources/SextantApp/Automation.swift` (test harness), and `Sources/sextant/main.swift` (CLI), following calls into `JumpActions.swift`, `RepoWindowController.swift`, `Repository.swift`, `Settings.swift`, `SearchPath.swift`, `Git.swift`, `Review.swift`, `Reading.swift`, `Document.swift`, `Reader.swift`, and `CodeView.swift`.

All microbenchmarks and adversarial reproduction tests were compiled in release mode against the real `SextantCore` sources and exact extracts of the `SextantApp` and `sextant` CLI logic in `/Users/shrik450/Developer/review-ui/scratch/review/argon-sections/app/`.
To rerun all benchmarks and adversarial tests:

```bash
cd /Users/shrik450/Developer/review-ui/scratch/review/argon-sections/app && nix develop /Users/shrik450/Developer/review-ui -c swift build -c release && ./.build/release/AppAuditBench
```

---

## 1. Architecture Audit

### Ownership and Data Flow
- **`AppDelegate` (`Sources/SextantApp/main.swift:4-311`)**:
  - `@MainActor` `NSApplicationDelegate` and `NSMenuItemValidation` root owner of application lifecycle, the global menu bar (`buildMainMenu()`, `:156-308`), the singleton `Settings` window (`settingsWindow`, `:6, 137-146`), the optional `Automation` driver (`:7`), `gitPath` resolution (`:12-20`), and all open repository window controllers (`controllers: [RepoWindowController]`, `:5`).
  - Handles launch entry points (`applicationWillFinishLaunching`, `applicationDidFinishLaunching`, `application(_:open:)`, `applicationShouldHandleReopen`), repository window creation and deduplication by `commonDir` (`openRepo(path:spec:completion:)`, `:78-112`), and persistence of open checkout paths in `UserDefaults` under `"openRepos"` (`saveOpenRepos()`, `:122-125`).
- **`RepoWindowController` Command & Validation Extensions (`Sources/SextantApp/WindowActions.swift:1-478`, `JumpActions.swift:1-151`)**:
  - `WindowActions.swift` extends `RepoWindowController` with review labeling (`subjectLabel`, `scopeLabel`, `updateTitle`, `card()`, `:6-120`) and `NSMenuItemValidation` + `@objc` action handlers (`:123-478`) for context menus (`navigatorFileMenu`, `navigatorCommitMenu`, `readerMenu`), external editor/Finder integration (`checkout`, `openInEditor`, `menuReveal`), symbol lookups (`lookUp`, `nearest`, `jumpToDefinition`, `showDefinitionsMenu`, `findReferences`, `peekDefinition`), blame & file history (`loadBlame`, `toggleBlame`, `showFileHistory`, `openHistoryCommit`), clipboard references (`selectedReference`, `copyReference`, `copyReferenceWithCode`, `symbolAtCaret`, `copySymbol`, `copySymbolWithReference`), notes (`addNote`, `addReviewNote`, `editNote`, `copyAllNotes`), navigation (`nextChange`, `previousChange`, `toggleChangeRead`, `nextFile`, `previousFile`, `stepFile`, `nextUnreviewed`, `goToLine`), and menu validation (`validateMenuItem`, `:429-477`).
  - Also owns global process environment helpers `shellQuote(_:)`, `userPath()`, and `loginShellPath` (`WindowActions.swift:480-510`).
  - `JumpActions.swift` extends `RepoWindowController` with `goToAnything(_:)`, `indexDefinitions(_:)`, `forgetDefinitions(_:)`, `jumpItems(for:)`, `jump(to:beside:)`, and custom menu-tree command harvesting (`enabledCommands(in:path:)`, `commandTarget(for:)`, `responders()`, `:108-140`).
- **`Automation` (`Sources/SextantApp/Automation.swift:28-539`)**:
  - `@MainActor` test/benchmark harness launched via `--automation <script> [--background] [--log <file>]` (`main.swift:30-35`).
  - Executes line-oriented commands (`open`, `timeopen`, `wait`, `key`, `type`, `click`, `rclick`, `hover`, `drag`, `scroll`, `hscroll`, `menu`, `measure`, `settle`, `snapshot`, `render`, `dump`, `sh`, `quit`) against `window` (resolved dynamically from `NSApp.keyWindow ?? NSApp.mainWindow ?? app.controllers.last`, `:31-34`) and serializes UI state via `RepoWindowController.stateSnapshot()` (`:380-496`).
- **`sextant` CLI (`Sources/sextant/main.swift:1-114`)**:
  - Standalone executable target (`Package.swift:9, 18`) with **zero dependency on `SextantCore`**.
  - Parses `[path] [revision]`, locates `Sextant.app` by walking up from `CommandLine.arguments[0]` or querying `NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.shrikanthup.Sextant")`, runs `git rev-parse --show-toplevel` and `git rev-parse --verify -q <side>^{commit}` via synchronous `Process` pipes, constructs a `sextant://open?path=<top>&rev=<rev>` URL, and opens it via `NSWorkspace.shared.open([url], withApplicationAt: appURL, ...)`.

### What Is in the Wrong Place or Duplicated
1. **CLI (`Sources/sextant/main.swift`) duplicates git execution, path resolution, and revision parsing instead of sharing `SextantCore`, and repeats work `SextantApp` immediately redoes**:
   - `Sources/sextant/main.swift` reimplements `git()` (`:68-80`), revision keyword matching (`:83`), `...`/`..` range splitting (`:85-91`), and `rev-parse --show-toplevel` (`:80`).
   - Because the CLI does not link `SextantCore`, its revision parser has drifted out of sync with `SextantCore.parseRevisionSpec` (`Review.swift:75-92`) and `AppDelegate.openRepo` (`main.swift:80-82`) — see **Finding 5**.
   - Worse, running `sextant . main..feature` spawns **3 synchronous `git` processes in the CLI** (`rev-parse --show-toplevel` and two `rev-parse --verify` calls) before sending `sextant://open?path=...&rev=main..feature` to `Sextant.app`, which immediately spawns `Git.locate` (`rev-parse --show-toplevel --git-common-dir`), `Repository.open` (`Repository.review(for:)` + `Resolver.resolve`), AND `RepoWindowController.start` (`existing.open(spec:)` -> `repository.review(for:)` again)!
2. **`loginShellPath` and `userPath()` live at the bottom of `WindowActions.swift` (`:484-510`) and block `@MainActor` via `swift_once` during launch**:
   - `applicationWillFinishLaunching` (`main.swift:23`) dispatches `DispatchQueue.global(qos: .userInitiated).async { _ = loginShellPath }` to warm the login shell `PATH` off the main thread.
   - However, `applicationDidFinishLaunching` (`:36-47`) and `application(_:open:)` (`:60-71`) run only milliseconds later on `@MainActor`, calling `openRepo` -> `Task { ... executable: gitPath }`, which accesses `self.gitPath` on `@MainActor` (`:82`).
   - Whenever `SEXTANT_GIT` and `SextantGitPath` are unset, `gitPath` (`:15`) calls `userPath()`, which reads `loginShellPath` — blocking `@MainActor` inside `swift_once` until the login shell finishes (or forever if a login script background process keeps stdout open; see **Finding 1**).
3. **Bare-key keyboard commands are implemented as global `NSMenuItem` key equivalents in `NSApp.mainMenu` (`main.swift:166-308`) with an `isEditable` hack in `validateMenuItem` (`WindowActions.swift:430-433`)**:
   - Putting 20+ single-letter/punctuation shortcuts (`e`, `f`, `o`, `Shift+B`, `[`, `]`, `s`, `p`, `d`, `Shift+D`, `*`, `n`, `Shift+N`, `Shift+J`, `Shift+K`, `Shift+L`, `Shift+H`, `u`, `r`, `Shift+R`, `c`, `Shift+C`) on `NSApp.mainMenu` and disabling them in `validateMenuItem` whenever `window?.firstResponder` is an editable `NSTextView` conflates *key-equivalent interception* with *menu command availability*.
   - As proven in **Finding 3**, whenever focus is in the File Filter (`⌘⌥F`) or Find in Files (`⌘⇧F`), opening `Go to Anything` (`⌘K`) or clicking the menu bar disables and hides all 20 commands! Conversely, when a child `NSPanel` (`JumpPanel` or `RevisionSheet`) is the `keyWindow`, `self.window?.firstResponder` is still `CodeView` (`isEditable == false`), so the guard checks the wrong window!
4. **Shared `searchGeneration` counter across unrelated subsystems (`RepoWindowController.swift:83`, `WindowActions.swift:208, 250, 329`, `RepoWindowController.swift:1007`)**:
   - `jumpToDefinition`, `findReferences`, `peekDefinition`, and `navigatorSearch` (`Find in Files`) all increment the same `RepoWindowController.searchGeneration` integer, without cancelling the underlying `git.grep` / `definitions.lookUp` `Task`s, and without tying `jumpToDefinition` / `peekDefinition` / `showFileHistory` to the originating pane, file, or caret generation (**Finding 8**).

### Unenforced Invariants
1. **One-window-per-repository invariant (`main.swift:75-105`)**:
   - `openRepo` claims *"A repository has one window, whichever worktree it's opened from; opening another of its worktrees reviews that one in the same window."*
   - Nothing enforces this across:
     - **Symlinked or `/var` vs `/private/var` worktrees**: `Git.locate` (`Git.swift:92`) returns a relative `.git` resolved against the input path for the main worktree (`/var/.../sym/repo/.git`), but an absolute realpath (`/private/var/.../real/repo/.git`) for linked worktrees. `openRepo` compares `.standardizedFileURL`, which evaluates to `false` and opens a **second window for the same repository** (**Finding 4**).
     - **Concurrent `openRepo` calls before `Git.locate` returns**: `openRepo` checks `controllers` *after* `try await Git.locate(...)` (`main.swift:82-83`) with no in-flight table by path/commonDir.
     - **Concurrent `openRepo` while `wc.start` is awaiting `opening.value`**: `wc` is appended to `controllers` (`main.swift:97`) *before* `wc.start(spec:opening:)` (`RepoWindowController.swift:225-239`) finishes `await opening.value` and `await repository.refreshRefs(o.refs)`. A second `openRepo` (or `application(_:open:)`) finding `existing = wc` runs against empty `repository.branches`/`defaultBase`, and is then overwritten when `wc.start` finishes `await opening.value` and calls `openWork(in: home)` (**Finding 4**).
2. **Unique window frame autosave names across multiple windows (`RepoWindowController.swift:127-128`)**:
   - Every `RepoWindowController` calls `window.setFrameAutosaveName("SextantWindow")`. AppKit rejects duplicate autosave names on open windows (`setFrameAutosaveName` returns `false` on Window 2+), preventing frame persistence and stacking every subsequent window at the exact same screen coordinates (**Finding 6**).
3. **Per-window vs global idle tracking (`RepoWindowController.swift:88-89`, `Automation.swift:71-78`)**:
   - `RepoWindowController.idleWaiters` is `static`, so any window's `busy` hitting `0` resumes continuations waiting on a different window (**Finding 9**).

### How This Scope Fits the Plan's Target Design (`scratch/perf/plan.md`)
- **Step 0 (Guardrails & Benchmark Harness)**: Fix `Automation.swift` bugs (`sendKey("cmd++")`, `sendKey` menu dispatch in `--background` mode when `NSApp.keyWindow == nil`, per-window `idleWaiters`, and `waitIdle()` returning before `reader.isSettled`) so automated benchmarks and tests measure real work accurately (**Finding 9**).
- **Step 1 (Confirmed bugs)**:
  - Canonicalize `Git.locate`'s `root` and `commonDir` with `Darwin.realpath`, serialize/track in-flight `openRepo` + `wc.start` loads so `wc.start` cannot clobber a concurrent `open(spec:in:)`, and call `saveOpenRepos()` when `existing` switches worktrees (**Finding 4**).
  - Fix `validateMenuItem` so bare-key shortcuts are only suppressed during `performKeyEquivalent` (or handled in responder `keyDown`), check `NSApp.keyWindow?.firstResponder` instead of `window?.firstResponder`, and fix `copySymbol` validation to check `symbolAtCaret != nil` (**Finding 3**).
  - Fix `nearest(_:to:)` to drop the filename component (`.dropLast()`) and rank by directory tree distance (**Finding 7**).
  - Guard `showDefinitionsMenu` against `selectedRange().location >= textStorage.length`, and tie `jumpToDefinition`, `peekDefinition`, and `showFileHistory` to pane/file/caret state with separate task handles from `Find in Files` (**Finding 8**).
  - Link `SextantCore` in `sextant` CLI (or share revision/path resolution) and replace the 4.8M-iter/sec `RunLoop.current.run(until:)` spin loop (**Finding 2**, **Finding 5**).
- **Step 2 (Limits & lifetimes)**:
  - Kill the entire process group (`kill(-p.processIdentifier, SIGTERM)`) and close pipe fds on `loginShellPath` timeout so background login daemons cannot hang launch; cache `userPath()` (**Finding 1**).
  - Cap line prefix before trimming in `showDefinitionsMenu` (**Finding 8**).
- **Step 3 (Cheap UI fast paths)**:
  - Make `validateMenuItem` and `enabledCommands` $O(1)$ per item (cache `responders()` once per `enabledCommands`, convert `actionPaths` to `Set`, check `caretLine` change status directly without hashing all `keyedRuns`, check `notes.hasNotes(about:)` without sorting) (**Finding 3**).
  - Precompute directory components in `nearest(_:to:)` (**Finding 7**), cache the static review header in `card()` during `blameOn` caret movement (**Finding 8**), lazy-load `secondary` `CodeView` only when `split == true`, and compute `SettingsView.monospacedFamilies` off the main thread (**Finding 6**).

---

## 2. Efficiency Summary

| Operation / Component | Current Work & Allocations | Complexity | Measured Cost / Waste |
| :--- | :--- | :--- | :--- |
| `sextant` CLI `NSWorkspace.shared.open` wait loop (`Sources/sextant/main.swift:111-113`) | Calls `RunLoop.current.run(until: Date().addingTimeInterval(0.01))` in `while outcome.done.wait(timeout: .now()) == .timedOut`; because `RunLoop.current` has no input sources, `run(until:)` returns immediately without sleeping | Tightbusy-spin loop on main thread | **281,670 iterations in 57.8 ms (~4,875,580 spins/sec, 100% CPU)** vs **1 blocking `outcome.done.wait()` call (0% CPU)**. |
| `enabledCommands` (`⌘K`) + `validateMenuItem` (`JumpActions.swift:108-140`, `WindowActions.swift:429-477`) | Rebuilds `responders()` 62x; scans `scopeRows` 62x; runs `changes.filter { paths.contains($0.path) }` ($O(C \times P)$, 2x with alternate); computes `f.keyedRuns` ($O(L)$ FNV-1a hashes, 2x with alternate); filters & sorts `reviewNotes` | $O(\text{items} \cdot \text{chain} + C \cdot P + L + N \log N)$ on `@MainActor` | **12.58 ms** ($C=5\text{k}, P=1\text{k}, L=10\text{k}$) to **101.59 ms** ($C=10\text{k}, P=5\text{k}, L=50\text{k}$) vs **0.05 ms** / **0.20 ms** optimized (**251x–508x faster**). |
| `nearest(_ defs:to:)` (`WindowActions.swift:196-205`) | Calls `p.split(separator: "/")` and `zip(here, ...)` inside the `.sorted` comparator on every comparison | $O(D \log D \cdot \text{depth})$ string splits & array allocations on `@MainActor` | **26.90 ms** at 1,000 defs and **247.88 ms** at 10,000 defs vs **1.60 ms** / **14.18 ms** with precomputed directory keys (**16.8x–17.5x faster**). |
| `SettingsView.monospacedFamilies` (`Settings.swift:13-16`) | Instantiates `NSFont(name: fam, size: 12)` and queries CoreText `.isFixedPitch` for every installed font family on macOS when Settings first opens | $O(\text{installed font families})$ synchronous CoreText font instantiation on `@MainActor` | **85.89 ms–122.77 ms** main-thread stall on first Settings open (181 font families). |
| `userPath()` (`WindowActions.swift:484-488`) | Queries `homeDirectoryForCurrentUser`, `NSUserName()`, builds `known` array, splits & deduplicates `PATH` on every call (`gitPath`, `openInEditor`, `loadPullRequests`, `Automation`) | $O(|\text{PATH}|)$ per call | **129.24 ms** per 10k calls uncached vs **0.0022 ms** as a `let` constant. |
| `loginShellPath` (`WindowActions.swift:495-510`, `main.swift:12-23, 82`) | Spawns `<shell> -l -c /usr/bin/env`, reads entire environment, parses `PATH=`; accessed on `@MainActor` via `gitPath` during `openRepo`, blocking on `swift_once` | 1 login shell process (**25–40 ms** on fast fish config, up to **5,000 ms** on heavy shell configs, or **infinite** if child holds stdout) | Blocks `@MainActor` during launch if `SEXTANT_GIT` / `SextantGitPath` is not set; hangs past 5s timeout if a login daemon inherits stdout (**384.1 ms** block on a 50 ms timeout in test). |
| `card()` on caret move with `blameOn` (`WindowActions.swift:64-130`, `RepoWindowController.swift:1066`) | Formats dates via `Date.formatted` 2x, scans `repository.branches` ($O(B)$) and `worktrees`, rebuilds `NSMutableAttributedString`, and reloads the entire Inspector `NSOutlineView` on every line move | $O(B)$ + 2 ICU date formats + full outline reload per caret move | **68.57 ms** for 500 moves (**0.14 ms/move** in `card()` alone before `Inspector.outline.reloadData()`). |
| Per-Pane `Reader` allocation (`Reader.swift:26-27`, `RepoWindowController.swift:140`) | Eagerly allocates 2 full TextKit 1 stacks (`primary` and `secondary` `CodeView` + `GutterScrollView` + `Gutter` + `NSTextStorage` + `NSLayoutManager` + `NSTextContainer`) per `Pane` even in Unified mode | $2\times$ TextKit 1 view & layout hierarchies per pane | **1.84 ms** (20 scrollviews for 10 panes) vs **0.35 ms** (10 scrollviews) with lazy `secondary` (**5.3x faster**). |

---

## 3. Ranked Findings (Bugs, Slowness, Waste, Architecture)

*Note: Known findings already in `scratch/perf/plan.md` are omitted unless refined below with new root causes, failure modes, or benchmark measurements.*

---

### Finding 1 (Bug + Slowness — High Impact): `loginShellPath` can block `@MainActor` at launch via `swift_once`, hangs indefinitely past its 5-second timeout if any login-shell child process inherits `stdout`, and `pathVariable(inEnvironment:)` can be hijacked by multiline environment variables
- **Location**: `Sources/SextantApp/main.swift:12-26, 82`, `Sources/SextantApp/WindowActions.swift:484-510`, `Sources/SextantCore/SearchPath.swift:5-7`
- **Category**: Bug + Slowness
- **Plan Step**: Step 1 (Confirmed bugs) & Step 2 (Limits and lifetimes)
- **Evidence**:
  1. **Main-thread `swift_once` block at launch (`main.swift:12-26, 82`)**:
     `applicationWillFinishLaunching` (`main.swift:23`) dispatches `DispatchQueue.global(qos: .userInitiated).async { _ = loginShellPath }`.
     Immediately afterward, `applicationDidFinishLaunching` (`:36-47`) or `application(_:open:)` (`:60-71`) calls `openRepo(path:spec:)`, which starts a `@MainActor` `Task` that evaluates `self.gitPath` (`:82`) on `@MainActor`.
     Whenever `SEXTANT_GIT` and `SextantGitPath` are unset, `gitPath` (`:15`) calls `userPath()` (`WindowActions.swift:484`), which reads the global `let loginShellPath: String?` (`:495`). Because `loginShellPath` is still running `<shell> -l -c /usr/bin/env` on the background queue, **`swift_once` blocks `@MainActor` synchronously** until the login shell exits!
  2. **Infinite hang past the 5-second timeout when a login script spawns a background daemon (`WindowActions.swift:495-510`)**:
     ```swift
     guard (try? p.run()) != nil else { return nil }
     DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if p.isRunning { p.terminate() } }
     let data = out.fileHandleForReading.readDataToEndOfFile()
     p.waitUntilExit()
     ```
     `out.fileHandleForReading.readDataToEndOfFile()` blocks until **every process holding the write file descriptor of `out` closes it**.
     If the user's `.zprofile`, `.bash_profile`, or `config.fish` starts any background helper (such as `ssh-agent`, `gpg-agent`, `direnv`, or a nix daemon) that inherits `stdout` (`fd 1`), `p.terminate()` only sends `SIGTERM` to `p` (or `p` already exited normally), while the grandchild still holds the pipe write end open — so `readDataToEndOfFile()` **blocks past the timeout (potentially forever)**!
  3. **Multiline environment variable spoofing in `pathVariable(inEnvironment:)` (`SearchPath.swift:5-7`)**:
     `loginShellPath` runs `/usr/bin/env` and searches for `.last { $0.hasPrefix("PATH=") }`. Any environment variable printed after `PATH` whose value contains `\nPATH=...` overwrites the extracted `PATH`. Running `/usr/bin/printenv PATH` outputs only `PATH` directly.
  4. **Repeated `userPath()` allocations (`WindowActions.swift:484-488`)**:
     `userPath()` is a function rather than a `let` constant, re-querying `homeDirectoryForCurrentUser`, `NSUserName()`, and running `searchPath(...)` on every call (**129.24 ms** per 10k calls vs **0.0022 ms** cached).
  - **Benchmark & reproduction output from `AppAuditBench` (`=== 1. Launch, loginShellPath, userPath(), and CLI Tests ===`)**:
    ```text
    [loginShellPath (/run/current-system/sw/bin/fish -l -c /usr/bin/env)]: median 25.11 ms, p90 39.89 ms, max 39.89 ms (match=true)
    [printenv PATH  (/run/current-system/sw/bin/fish -l -c '/usr/bin/printenv PATH')]: median 25.04 ms, p90 28.47 ms, max 28.47 ms
    [Adversarial loginShellPath grandchild pipe leak]: timeout=50ms, actual block=384.1ms (blocked until grandchild exited despite shell exiting immediately! bytes=19)
    [Adversarial pathVariable multiline env]: extracted='/tmp/hijacked' (expected '/nix/store/real-bin:/usr/bin:/bin', got hijacked=true)
    [userPath() x10000]: uncached 129.24 ms vs cached 0.0022 ms (sink=8400000)
    ```
- **Fix**:
  - Resolve `gitPath` and `userPath` off the main actor (or check the fast `known` paths first for `git` before blocking on `loginShellPath`, and cache `userPath` once).
  - In `loginShellPath`, run `/usr/bin/printenv PATH`, put the child in its own process group (`posix_spawnattr_setpgroup`), and on timeout kill the process group and close the read pipe (`try? out.fileHandleForReading.close()`) so `readDataToEndOfFile()` cannot hang on grandchild descriptors.

---

### Finding 2 (Waste + Slowness — High Impact): `sextant` CLI spins at 4.88 million iterations/sec (100% CPU) in `RunLoop.current.run(until:)` while waiting for `NSWorkspace.shared.open`
- **Location**: `Sources/sextant/main.swift:101-114`
- **Category**: Waste + Slowness
- **Plan Step**: Step 1 (Confirmed bugs) & Step 2 (Limits and lifetimes)
- **Evidence**:
  Look at `Sources/sextant/main.swift:109-113`:
  ```swift
  NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config) { _, error in
      outcome.error = error
      outcome.done.signal()
  }
  while outcome.done.wait(timeout: .now()) == .timedOut {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
  }
  ```
  In Foundation, `RunLoop.current.run(until: limitDate)` returns **immediately** (in ~0.2 µs) without sleeping whenever the `RunLoop` has no input sources or timers registered in `.default` mode. Because `NSWorkspace.shared.open` delivers its completion handler on a GCD queue rather than adding an input source to `RunLoop.current`, the `while outcome.done.wait(timeout: .now()) == .timedOut` loop spins at **100% CPU (~4.88 million iterations per second)** for the entire 50–300 ms LaunchServices open round-trip!
  - **Benchmark numbers from `AppAuditBench` (`=== 1. Launch, loginShellPath, userPath(), and CLI Tests ===`)**:
    ```text
    [CLI RunLoop.current.run(until: +10ms) during 50ms wait]: spun 281670 times in 57.8 ms (expected ~5 iterations if it actually slept 10ms, actual=4875580 spins/sec 100% CPU busy-wait!)
    ```
- **Fix**:
  - Replace the polling loop with `outcome.done.wait()` (or if main-queue callbacks are needed, `CFRunLoopRunInMode(.defaultMode, 0.01, true)` / `outcome.done.wait(timeout: .now() + .milliseconds(10))`).

---

### Finding 3 (Bug + Slowness — High Impact): `validateMenuItem` disables 20 bare-key commands in the menu bar and drops them from `Go to Anything` (`⌘K`) whenever a filter/search field has focus, checks `window?.firstResponder` instead of `NSApp.keyWindow?.firstResponder`, disables `Copy Symbol Name` on enclosing symbols, and stalls `@MainActor` up to 102 ms at scale
- **Location**: `Sources/SextantApp/WindowActions.swift:361-379, 429-477`, `Sources/SextantApp/JumpActions.swift:7, 108-140`, `Sources/SextantApp/main.swift:166-308`
- **Category**: Bug + Slowness + Architecture
- **Plan Step**: Step 1 (Confirmed bugs) & Step 3 (Cheap UI fast paths)
- **Evidence**:
  1. **20 commands disappear from `Go to Anything` (`⌘K`) and disable in the menu bar when a text field is focused (`WindowActions.swift:430-433`, `JumpActions.swift:7, 108-127`)**:
     ```swift
     func validateMenuItem(_ item: NSMenuItem) -> Bool {
         if item.keyEquivalentModifierMask.subtracting(.shift).isEmpty, !item.keyEquivalent.isEmpty,
            let text = window?.firstResponder as? NSTextView, text.isEditable {
             return false
         }
     ```
     When the cursor is in the File Filter (`⌘⌥F`), Find in Files (`⌘⇧F`), or `NoteEditor`:
     - Clicking **File**, **View**, **Go**, or **Review** in the menu bar shows **20 menu commands grayed out and disabled** solely because their primary shortcut happens to be a single key.
     - Pressing `⌘K` (`goToAnything`, `JumpActions.swift:7`) calls `jumpCommands = enabledCommands(in: NSApp.mainMenu)` *before* `panel.show(over: window)`. Because `window.firstResponder` is still the filter/search `NSTextView`, `validateMenuItem` returns `false` for all 20 bare-key commands, **dropping them from `Go to Anything` (`> ...`)**:
       `Add Note`, `Add Note on Whole Review`, `Blame`, `Find References`, `Highlight Uses`, `Jump to Definition`, `Jump to Text…`, `Mark Change as Read`, `Mark File as Reviewed`, `Next Change`, `Next File`, `Next Unreviewed File`, `Next Use`, `Open in Editor`, `Peek Definition`, `Previous Change`, `Previous File`, `Previous Use`, `Show Nearby Unchanged Lines`, `Show Unchanged Lines`.
  2. **Wrong window checked for editable `NSTextView` (`WindowActions.swift:431`)**:
     `validateMenuItem` checks `let text = window?.firstResponder as? NSTextView, text.isEditable`. When a child `NSPanel` (`JumpPanel` or `RevisionSheet`) is `NSApp.keyWindow`, `self.window?.firstResponder` is still `CodeView` (`isEditable == false`), so the guard inspects the parent window's responder instead of `NSApp.keyWindow?.firstResponder`!
  3. **`Copy Symbol Name` validation bug (`WindowActions.swift:361-373, 455-456`)**:
     `copySymbol(_:)` copies `symbolAtCaret` (which falls back to `reader.header.enclosing(line:)?.name` when `reader.wordAtCaret` is `nil`, e.g. when lines are selected or the caret is on whitespace inside a function). Yet `validateMenuItem` (`:455`) checks `return reader.wordAtCaret != nil` for `copySymbol(_:)` while checking `symbolAtCaret != nil && selectedReference != nil` for `copySymbolWithReference(_:)`. Thus `Copy Symbol with Reference` is enabled while `Copy Symbol Name` is disabled!
  4. **Up to 102.8 ms main-thread stall in `enabledCommands` / `validateMenuItem` (`JumpActions.swift:108-140`, `WindowActions.swift:435-463`)**:
     Every `enabledCommands(in: NSApp.mainMenu)` call (on `⌘K`) or menu-bar open:
     - Rebuilds the `responders()` array **62 times** (`JumpActions.swift:129-140`).
     - Evaluates `let commitRows = navigator.changes.scopeRows.contains { ... }` **62 times** (`WindowActions.swift:435`), even for items that don't use `commitRows`.
     - Evaluates `changes.filter { paths.contains($0.path) }` ($O(C \times P)$, `WindowActions.swift:442` — called **twice** during key-equivalent matching because of the hidden `alternate` item).
     - Evaluates `reader.caretRun` -> `f.keyedRuns` (`WindowActions.swift:461` — scanning all `f.lines` and computing FNV-1a `changeKey` hashes for every change run in the file just to check whether the caret is on a changed line!).
     - Evaluates `!reviewNotes.isEmpty` (`WindowActions.swift:458` — filtering and sorting all notes in `NotesStore` via `readingOrder` just to test non-emptiness!).
  - **Benchmark & reproduction output from `AppAuditBench` (`=== 3. Menus, validateMenuItem, enabledCommands & Bare-Key Shortcut Tests ===`)**:
    ```text
    [enabledCommands when CodeView focused]:      62 commands
    [enabledCommands when Filter/Search focused]: 42 commands (dropped 20 commands!)
    [Copy Symbol validation when wordAtCaret==nil but enclosing symbol exists]:
      'Copy Symbol with Reference' enabled: true
      'Copy Symbol Name' enabled:           false (BUG: disabled even though copySymbol() uses symbolAtCaret!)
    [enabledCommands / validateMenuItem (C=1000, P=200, L=1000)]:
      Current:   median 1.05 ms, p90 1.07 ms, max 1.09 ms
      Optimized: median 0.02 ms, p90 0.03 ms, max 0.03 ms (52x faster)
    [enabledCommands / validateMenuItem (C=5000, P=1000, L=10000)]:
      Current:   median 12.58 ms, p90 12.74 ms, max 12.86 ms
      Optimized: median 0.05 ms, p90 0.05 ms, max 0.06 ms (251x faster)
    [enabledCommands / validateMenuItem (C=10000, P=5000, L=50000)]:
      Current:   median 101.59 ms, p90 102.77 ms, max 102.93 ms
      Optimized: median 0.20 ms, p90 0.22 ms, max 0.23 ms (508x faster)
    ```
- **Fix**:
  - Suppress bare-key equivalents only when `NSApp.currentEvent?.type == .keyDown` and `(NSApp.keyWindow?.firstResponder as? NSTextView)?.isEditable == true` (never when populating `enabledCommands` or opening menus in the menu bar).
  - In `validateMenuItem`: validate `copySymbol(_:)` with `symbolAtCaret != nil`; move `commitRows` into `case #selector(olderCommit(_:)), #selector(newerCommit(_:)):`; use `Set(actionPaths)` in `toggleReviewedAction`; check `notes.hasNotes(about:)` without sorting; and in `toggleChangeRead` check whether the caret's line is non-`.context` before computing `keyedRuns` (or cache `responders()` once per `enabledCommands` call).

---

### Finding 4 (Bug — High Impact): `AppDelegate.openRepo` breaks its one-window-per-repository invariant on symlinked/`/var` worktrees, and races with `RepoWindowController.start` when a second open arrives while initial ref loading is in flight
- **Location**: `Sources/SextantApp/main.swift:75-105, 122-125`, `Sources/SextantCore/Git.swift:87-94`, `Sources/SextantApp/RepoWindowController.swift:225-239`
- **Category**: Bug + Concurrency
- **Plan Step**: Step 1 (Confirmed bugs) & Step 4 (Refresh coordinator)
- **Evidence**:
  1. **Symlink / `/var` vs `/private/var` `commonDir` mismatch opens two windows for the same repository (`main.swift:83`, `Git.swift:87-94`)**:
     In `Git.locate` (`Git.swift:87-94`):
     ```swift
     let out = String(decoding: try await run(executable, in: path, ["rev-parse", "--show-toplevel", "--git-common-dir"]), as: UTF8.self)
     let lines = out.split(separator: "\n").map(String.init)
     let root = URL(fileURLWithPath: lines[0], isDirectory: true)
     let common = lines[1].hasPrefix("/") ? URL(fileURLWithPath: lines[1], isDirectory: true) : URL(fileURLWithPath: lines[1], isDirectory: true, relativeTo: path).standardizedFileURL
     ```
     When run in a main worktree accessed via a symlink or `/var/...` (or `/tmp/...`), `git rev-parse --git-common-dir` outputs relative `".git"`, which `Git.locate` resolves relative to the unresolved `path` (`/var/.../sym/repo/.git`).
     When run in a linked worktree of the **same repository** (or via the realpath), `git rev-parse --git-common-dir` outputs the absolute realpath (`/private/var/.../real/repo/.git`).
     In `AppDelegate.openRepo` (`main.swift:83`), `$0.repository.commonDir.standardizedFileURL == loc.commonDir.standardizedFileURL` evaluates to **`false`**, opening a **second `RepoWindowController` window for the same repository**!
  2. **Race between `wc.start(spec:opening:)` and a second `openRepo` finding `existing` (`main.swift:83-102`, `RepoWindowController.swift:225-239`)**:
     When `openRepo` #1 creates `wc` and appends it to `controllers` (`main.swift:96-97`), `wc.start(spec: spec, opening: opening)` (`RepoWindowController.swift:225`) spawns a `Task` that suspends at `let o = await opening.value`.
     If `openRepo` #2 (e.g., from `application(_:open:)` with a `sextant://` URL or a second entry in `openRepos`) finishes `Git.locate` while `opening.value` is still in flight:
     - `openRepo` #2 finds `existing = wc` (`main.swift:83`) and immediately runs `await existing.open(spec: spec2, in: loc.root)` (`:86`).
     - Because `wc.start` has not yet run `await repository.refreshRefs(o.refs)`, `existing.repository.branches`, `stashes`, `worktrees`, and `defaultBase` are all **empty (`[]` / `nil`)**! Thus `existing.open(spec: "feature", ...)` fails to find `"feature"` in `repository.branches` and opens it as a detached `.commit(oid)` (or opens a worktree with `base: nil`).
     - Then, when `opening.value` finishes milliseconds later, `wc.start` (`RepoWindowController.swift:232-236`) unconditionally runs `openWork(in: home)` (from `openRepo` #1), **clobbering `openRepo` #2's review**!
  3. **Missing `saveOpenRepos()` when `existing` switches worktrees (`main.swift:83-90`)**:
     When `existing` is reused to open another worktree `loc.root` (`existing.openWork(in: loc.root)`, which mutates `existing.home = loc.root`), `openRepo` returns at line 89 without calling `saveOpenRepos()`, leaving the stale worktree path in `UserDefaults` `"openRepos"`.
  - **Reproduction output from `AppAuditBench` (`=== 2. Multi-Window & openRepo Deduplication / Window Frame Tests ===`)**:
    ```text
    [Git.locate main worktree via symlink]: commonDir.standardizedFileURL = /var/folders/.../sym/repo/.git
    [Git.locate linked worktree of same repo]: commonDir.standardizedFileURL = /private/var/folders/.../real/repo/.git
    [AppDelegate.openRepo deduplication match (.standardizedFileURL ==)]: false (BUG: false! Opens 2nd window for same repo!)
    [Deduplication match with Darwin.realpath]:                           true (true!)
    [openRepo #2 ('feature') while wc.start opening in flight]:
      During openRepo #2 (before refreshRefs): commit:resolved(feature) (BUG: resolved branch 'feature' as commit because branches=[]!)
      After wc.start opening finishes:         worktree:/repo (BUG: wc.start overwrote 'feature' with worktree:/repo!)
    ```
- **Fix**:
  - Canonicalize both `root` and `commonDir` in `Git.locate` using POSIX `Darwin.realpath`.
  - Keep an in-flight `openingRepos: [URL: Task<RepoWindowController?, Never>]` map in `AppDelegate` (or have `RepoWindowController` store its initial `startTask` so any subsequent `open(spec:in:)` / `openWork(in:)` awaits `refreshRefs` first and suppresses `start`'s default `openWork`/`open(spec:)`).
  - Call `saveOpenRepos()` when `existing` updates `home`.

---

### Finding 5 (Bug + Waste — Medium-High Impact): `sextant` CLI misclassifies branch names as paths when a matching directory exists, rejects file paths, rejects valid revision specs (`--staged`, `--cached`, `main..`, `..feature`), and runs 2–3 redundant synchronous `git` processes
- **Location**: `Sources/sextant/main.swift:41-96`
- **Category**: Bug + Waste + Architecture
- **Plan Step**: Step 1 (Confirmed bugs)
- **Evidence**:
  1. **Branch/tag names matching a subdirectory name are silently misclassified as `<path>` (`Sources/sextant/main.swift:45-49`)**:
     ```swift
     } else if args.count == 1 {
         let a = args[0]
         let looksLikePath = a.hasPrefix("/") || a.hasPrefix("./") || a.hasPrefix("../") || a.hasPrefix("~") || a == "." || a == ".."
         if looksLikePath || isDir(a) { path = a } else { rev = a }
     }
     ```
     If a repository has a directory (e.g., `docs`, `bench`, `nix`, `test`, `build`) and a branch or tag of the same name, running `sextant docs` from the repository root sees `isDir("docs") == true`, sets `path = "docs"` and `rev = nil`, runs `git rev-parse --show-toplevel` (which resolves right back to the repo root!), and opens the repo with `rev = nil` instead of reviewing the `docs` branch!
  2. **File paths are rejected with `not a directory` (`Sources/sextant/main.swift:51`, vs `SextantApp/main.swift:82`)**:
     The CLI usage states `Opens the repository containing <path>`, and `AppDelegate.openRepo` (`SextantApp/main.swift:82`) explicitly handles file paths (`url.hasDirectoryPath || isDirectory(url) ? url : url.deletingLastPathComponent()`). Yet `Sources/sextant/main.swift:51` guards `guard isDir(path) else { fail("\(path): not a directory") }`, failing whenever `<path>` is a file.
  3. **Revision validation drift vs `SextantCore.parseRevisionSpec` (`Sources/sextant/main.swift:83-96` vs `Review.swift:75-92`)**:
     - `parseRevisionSpec` accepts `--staged` and `--cached`; the CLI allowlist omits them and passes `--staged^{commit}` without `--end-of-options` to `git rev-parse`, which fails with `unknown revision: --staged`.
     - `parseRevisionSpec` accepts `..` and `...` on an unborn branch as `HEAD..HEAD`, while the CLI skips empty sides (`for s in sides where !s.isEmpty`) without verifying `HEAD`.
     - If a user passes a remote branch shorthand like `sextant feature` where only `origin/feature` exists (or a revision starting with `-`), the CLI's `rev-parse` behavior diverges from `Repository.review(for:)`.
  4. **Sequential `readDataToEndOfFile()` on stdout then stderr (`Sources/sextant/main.swift:75-76`)**:
     Reads `out` to EOF before reading `err`, without setting `GIT_OPTIONAL_LOCKS=0` or clearing `GIT_DIR`/`GIT_WORK_TREE`.
  - **Reproduction output from `AppAuditBench` (`=== 1. Launch, loginShellPath, userPath(), and CLI Tests ===`)**:
    ```text
    [CLI 'sextant docs' when both branch 'docs' and dir './docs' exist]: rev=nil (BUG: treated branch 'docs' as directory path, dropping rev!)
    [CLI 'sextant ./README.md' on a file]: isDirFinal=false (BUG: CLI exits with 'not a directory', while AppDelegate.openRepo supports file paths!)
    [CLI vs Core revision spec '--staged']: coreParsed=Optional(SextantCore.RevisionSpec.staged), cliAccepted=false
    [CLI vs Core revision spec '--cached']: coreParsed=Optional(SextantCore.RevisionSpec.staged), cliAccepted=false
    ```
- **Fix**:
  - Have `sextant` link `SextantCore` (which is already in the same `Package.swift`) and use `parseRevisionSpec`.
  - For a single argument `a` where `!looksLikePath`: if `cwd` is already inside a git repository and `a` resolves as a valid revision/branch/keyword in `cwd`, treat `a` as `rev` unless `a` is itself the root of a different git repository. Support file paths by taking `deletingLastPathComponent()` when `!isDir(path)` and `fm.fileExists(atPath: path)`.

---

### Finding 6 (Bug + Slowness — Medium-High Impact): Multiple repository windows collide on `setFrameAutosaveName("SextantWindow")`, `SettingsView.monospacedFamilies` stalls `@MainActor` for 86–123 ms, and every `Pane` eagerly allocates a hidden second `CodeView` TextKit 1 stack in Unified mode
- **Location**: `Sources/SextantApp/RepoWindowController.swift:127-128, 140-177`, `Sources/SextantApp/Reader.swift:26-27`, `Sources/SextantApp/Settings.swift:13-16`
- **Category**: Bug + Slowness + Waste (Multi-window & Per-window cost)
- **Plan Step**: Step 1 (Confirmed bugs) & Step 3 (Cheap UI fast paths)
- **Evidence**:
  1. **Multi-window `setFrameAutosaveName("SextantWindow")` collision (`RepoWindowController.swift:127-128`)**:
     ```swift
     window.setFrameAutosaveName("SextantWindow")
     if !window.setFrameUsingName("SextantWindow") { window.center() }
     ```
     AppKit enforces that only one open `NSWindow` in a process can hold a given `frameAutosaveName`. When a second repository window opens while Window 1 is open:
     - `window.setFrameAutosaveName("SextantWindow")` returns **`false`** and leaves `window.frameAutosaveName == ""` (so Window 2's frame changes are never saved).
     - `window.setFrameUsingName("SextantWindow")` places Window 2 at the **exact same screen coordinates** as Window 1 with zero cascade offset, completely hiding Window 1 behind Window 2!
  2. **`SettingsView.monospacedFamilies` synchronous CoreText stall on `@MainActor` (`Settings.swift:13-16`)**:
     ```swift
     private static let monospacedFamilies: [String] = NSFontManager.shared.availableFontFamilies.filter { fam in
         guard let f = NSFont(name: fam, size: 12) else { return false }
         return f.isFixedPitch || fam.localizedCaseInsensitiveContains("mono") || fam.localizedCaseInsensitiveContains("code")
     }
     ```
     When the user opens `Settings…` (`⌘,`), `monospacedFamilies` synchronously instantiates an `NSFont` and queries CoreText's `isFixedPitch` for every installed font family on the system (**85.89 ms–122.77 ms** on `@MainActor`).
  3. **Eager dual `CodeView` TextKit 1 stack per `Pane` (`Reader.swift:26-27`)**:
     Every `Pane` (`makePane()`, `RepoWindowController.swift:140`) initializes a `Reader` that eagerly constructs both `primary = CodeView(side: 0)` and `secondary = CodeView(side: 2)` (2 `NSTextStorage`s, 2 `NSLayoutManager`s, 2 `NSTextContainer`s, 2 `GutterScrollView`s, 2 `Gutter`s), even when the user is in Unified mode (`split == false`, the default) where `secondary` is hidden (**1.84 ms** vs **0.35 ms** for 10 panes, plus double the view-tree footprint).
  - **Benchmark & reproduction output from `AppAuditBench` (`=== 2. Multi-Window ===` & `=== 4. Command Layer ===`)**:
    ```text
    [Window 1 setFrameAutosaveName('SextantWindow')]: true, autosaveName='SextantWindowAuditTest'
    [Window 2 setFrameAutosaveName('SextantWindow')]: false (BUG: false while Window 1 is alive!), autosaveName='', frameIdenticalToW1=true
    [Per-pane TextKit stack allocation (10 panes)]: eager dual-CodeView 1.84 ms (20 scrollviews) vs lazy secondary 0.35 ms (10 scrollviews)
    [SettingsView.monospacedFamilies enumeration (181 total -> 7 mono)]: 85.89 ms synchronous on @MainActor
    ```
- **Fix**:
  - Use a per-repository frame autosave name (`"SextantWindow:\(repository.commonDir.path)"`), falling back to cascading from the last window's frame (`window.cascadeTopLeft(from:)`) when a repository is opened for the first time.
  - Compute `monospacedFamilies` asynchronously on a background queue (or filter via `CTFontDescriptorCreateMatchingFontDescriptors` with `kCTFontTraitsAttribute` / `kCTFontMonoSpaceTrait`).
  - Allocate `secondary` (`CodeView(side: 2)`) lazily when `split` is first set to `true`.

---

### Finding 7 (Bug + Slowness — Medium-High Impact): `nearest(_:to:)` in `WindowActions.swift` includes the filename as a directory component, ignores candidate directory depth, and re-splits paths on every sort comparison (248 ms at 10k definitions)
- **Location**: `Sources/SextantApp/WindowActions.swift:196-205`
- **Category**: Bug + Slowness
- **Plan Step**: Step 1 (Confirmed bugs) & Step 3 (Cheap UI fast paths)
- **Evidence**:
  Look at `RepoWindowController.nearest(_ defs: [GrepMatch], to path: String?)` (`WindowActions.swift:196-205`):
  ```swift
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
  ```
  1. **Bug 1 — Sibling files in the same directory lose to arbitrarily deep subdirectories whenever `closeness` ties**:
     When `path` is `"main.swift"` at the repository root (`here = ["main.swift"]`), a sibling file `"utils.swift"` at the repository root has `closeness == 0`, and `"a/b/c/d/e/deep.swift"` (5 subdirectories away!) also has `closeness == 0`. Because `"a/b/c/d/e/deep.swift" < "utils.swift"` lexicographically, `nearest` ranks `"a/b/c/d/e/deep.swift"` **ahead of `"utils.swift"`**! The same bug occurs inside any directory `dir/file.swift` when comparing a sibling `dir/z.swift` (`closeness == 1`) against `dir/a/b/c/d/deep.swift` (`closeness == 1`).
  2. **Bug 2 — `here` includes the filename instead of `.dropLast()`**:
     Because `here = path.split(separator: "/")` does not drop the filename component, if `path` is `"src/foo"` (an extensionless script or file) and a directory `"src/foo/sub/deep.swift"` exists, `zip` matches `"foo" == "foo"` and gives `"src/foo/sub/deep.swift"` `closeness = 2`, ranking it ahead of a sibling `"src/bar.swift"` (`closeness = 1`)!
  3. **Slowness — $O(D \log D \cdot \text{depth})$ repeated `split(separator: "/")` allocations on `@MainActor`**:
     `closeness(a.path)` and `closeness(b.path)` split both paths on every comparator invocation. At 10,000 definitions, `nearest` takes **247.88 ms** on `@MainActor` vs **14.18 ms** when precomputing the directory key once per element (**17.5x faster**).
  - **Benchmark & reproduction output from `AppAuditBench` (`=== 4. Command Layer ===`)**:
    ```text
    [Adversarial nearest() from 'main.swift' at root]:
      Current order: ["a/b/c/d/e/deep.swift", "utils.swift"] (BUG: picks 5-dirs-deep 'a/b/c/d/e/deep.swift' before sibling 'utils.swift'!)
      Fixed order:   ["utils.swift", "a/b/c/d/e/deep.swift"]
    [Adversarial nearest() from 'src/foo' when dir 'src/foo/sub/' exists]:
      Current order: ["src/foo/sub/ deep.swift", "src/bar.swift"] (BUG: filename 'foo' matched directory 'foo', ranking subdirectory ahead of sibling!)
      Fixed order:   ["src/bar.swift", "src/foo/sub/ deep.swift"]
    [nearest() scaling (N=100 definitions)]:   current median 1.62 ms vs precomputed median 0.12 ms (13.5x faster)
    [nearest() scaling (N=1000 definitions)]:  current median 26.90 ms vs precomputed median 1.60 ms (16.8x faster)
    [nearest() scaling (N=10000 definitions)]: current median 247.88 ms vs precomputed median 14.18 ms (17.5x faster)
    ```
- **Fix**:
  - Use `let hereDirs = path.split(separator: "/").dropLast()`, precompute `(sameFile: Bool, sharedDirs: Int, negTreeDistance: Int)` once per definition, and sort by `(sameFile, sharedDirs, negTreeDistance)` before `(path, line)`.

---

### Finding 8 (Bug + Waste — Medium Impact): `showDefinitionsMenu` crashes with `NSRangeException` when the caret is at EOF, trims full 1 MB minified lines before `.prefix(60)`, and `jumpToDefinition` / `peekDefinition` / `showFileHistory` / `findReferences` have stale-pane races and stuck `"Searching…"` states
- **Location**: `Sources/SextantApp/WindowActions.swift:207-317, 327-343`
- **Category**: Bug + Waste
- **Plan Step**: Step 1 (Confirmed bugs), Step 2 (Limits and lifetimes) & Step 3 (Cheap UI fast paths)
- **Evidence**:
  1. **`NSRangeException` crash in `showDefinitionsMenu` when caret is at EOF (`WindowActions.swift:241-245`)**:
     ```swift
     if let r = reader.caretRow, let lm = code.layoutManager, let tc = code.textContainer {
         let glyph = lm.glyphIndexForCharacter(at: code.selectedRange().location)
         let rect = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 0), in: tc)
         at = NSPoint(x: rect.minX + code.textContainerOrigin.x, y: code.rect(ofRow: r).maxY + 2)
     }
     ```
     If `code.selectedRange().location == code.textStorage?.length` (e.g., caret at the end of the document, or `code` changed while `await lookUp` was in flight), `lm.glyphIndexForCharacter(at:)` throws an uncaught Objective-C `NSRangeException`! Moreover, `code.rect(ofRow: r)` forces synchronous `ensureLayout` from glyph 0, whereas `reader.caretAnchor` (`Reader.swift:625`) already computes the caret anchor safely.
  2. **Stale-pane popups in `jumpToDefinition`, `peekDefinition`, and `showFileHistory` (`WindowActions.swift:212-227, 291-309, 332-342`)**:
     - `jumpToDefinition` and `peekDefinition` only check `gen == searchGeneration`, not whether the user switched panes, switched files, or moved the caret while `await lookUp` was running. `peekDefinition` captures `let anchor = reader.caretAnchor` *before* `await lookUp`, so if the user scrolled or closed the pane during `lookUp`, `peek.show(relativeTo: anchor.0, of: anchor.1)` anchors to a scrolled-away rect or detached view!
     - `showFileHistory` (`:283-310`) has **no generation or focus guard at all** after `await git.history(of: path, from: from, count: 100)`, popping up a modal `NSMenu` on `reader.header` even if the user switched to another file or pane! And `openHistoryCommit` (`:312-317`) passes the *current* `path` (`a[1]`) instead of the commit's pre-rename path from `git log --follow`, showing `"<path> isn't in this revision"` when selecting a pre-rename commit.
  3. **Stuck `"Searching…"` in `findReferences` on error (`WindowActions.swift:249-261`)**:
     `findReferences` calls `navigator.search.begin(word, word: true)` (setting `summary = "Searching…"`), then `guard let ... = try? await lookUp(word, in: t) else { return }`. If `lookUp` throws, `findReferences` returns early without updating `navigator.search.summary`, leaving `"Searching…"` stuck forever.
  4. **Unbounded line trimming in `showDefinitionsMenu` (`WindowActions.swift:238-239`) and `card()` rebuilds on every caret move (`:64-130`)**:
     - `d.text.trimmingCharacters(in: .whitespaces).prefix(60)` copies and trims the entire `GrepMatch.text` (which can be a 1 MB minified line) before taking `.prefix(60)` (**0.82 ms** vs **0.07 ms** with `d.text.drop { $0 == " " || $0 == "\t" }.prefix(60)`).
     - `card()` (`:64-130`) is rebuilt from scratch on every caret move when `blameOn == true` (`RepoWindowController.swift:1066`), running two `Date.formatted` calls, scanning `repository.branches` and `worktrees`, and calling `inspector.updateCard(card())` -> `outline.reloadData()` on every line move.
- **Fix**:
  - In `showDefinitionsMenu`, use `reader.caretAnchor` instead of calling `lm.glyphIndexForCharacter(at:)` and `code.rect(ofRow:)`, and bound `d.text` with `.drop { $0 == " " || $0 == "\t" }.prefix(60)`.
  - Give symbol lookups their own `lookupTask` / `lookupGeneration` separate from `Find in Files`, verify `(pane, focusedFile, caret)` after `await`, handle errors in `findReferences` by setting `navigator.search.summary = error.localizedDescription`, and cache the static review portion of `card()` separately from the blamed line footer.

---

### Finding 9 (Bug — Medium Impact): `Automation` harness drops `+` in `sendKey("cmd++")`, fails to route `cmd+...` menu shortcuts when `--background` is set (`NSApp.keyWindow == nil`), wakes `waitIdle()` across windows via static `idleWaiters`, and returns from `waitIdle()` before `reader.isSettled`
- **Location**: `Sources/SextantApp/Automation.swift:71-78, 207-255`, `Sources/SextantApp/RepoWindowController.swift:88-89`
- **Category**: Bug (Test & Benchmark Harness)
- **Plan Step**: Step 0 (Guardrails & Benchmark Suite)
- **Evidence**:
  1. **`sendKey("cmd++")` and `sendKey("shift++")` fail (`Automation.swift:212`)**:
     `let parts = combo.split(separator: "+").map(String.init)` drops `"+"` when `"+"` is the key itself: `"cmd++".split(separator: "+")` returns `["cmd"]` (`parts.count == 1`), leaving `flags = []` and `key = "cmd++"`!
  2. **`sendKey` fails for menu-only shortcuts (`cmd+k`, `cmd+0`, `cmd+shift+a`, etc.) when `--background` is active (`Automation.swift:252`)**:
     When `inBackground == true` (`--background`), `NSApp.isActive` is `false`, so `NSApp.keyWindow` and `NSApp.mainWindow` are both `nil`. When `sendKey` calls `NSApp.sendEvent(e)` for a menu key equivalent whose `NSMenuItem.target` is `nil`, `NSApp.mainMenu?.performKeyEquivalent(with: e)` queries `NSApp.target(forAction:)`, which walks `NSApp.keyWindow` (`nil`) -> `NSApp.mainWindow` (`nil`) -> `NSApp` -> `AppDelegate`, **never reaching `RepoWindowController`**! (By contrast, `case "menu":` at `Automation.swift:149` explicitly calls `window?.window?.firstResponder?.tryToPerform(action, with: item)`).
  3. **`waitIdle()` (`Automation.swift:71-78`) ignores `reader.isSettled` and shares `static var idleWaiters` across windows**:
     - `waitIdle()` only checks `w.busy > 0` for 3 iterations (plus a fixed 260 ms sleep floor), ignoring `w.reader.isSettled` (`Reader.analysis` does not increment `w.busy`), so `dump` or `snapshot` after `open`/`key` can capture pre-highlight/pre-symbol state.
     - `RepoWindowController.idleWaiters` (`RepoWindowController.swift:89`) is `static`, so a background window's `busy` hitting `0` prematurely resumes `waitIdle()` while the active window is still loading.
- **Fix**:
  - Parse `combo` in `sendKey` by splitting modifiers only before the trailing key (supporting trailing `"+"`), and when `inBackground == true` and `flags.contains(.command)` / `NSApp.mainMenu?.performKeyEquivalent` would run without a `keyWindow`, dispatch matching menu items through `w.firstResponder?.tryToPerform(action, with: item)`.
  - Move `idleWaiters` to an instance property on `RepoWindowController`, and have `waitIdle()` wait until `w.busy == 0 && w.reader.isSettled`.

---

## 4. Correctness Edge Cases That a Performance Rewrite Could Break

1. **Launch-time URL open (`application(_:open:)`) vs default session restoration (`applicationDidFinishLaunching`) (`main.swift:28-71`)**:
   - In AppKit, when an app is cold-launched via a custom URL scheme (`sextant://open?path=...`), `application(_:open:)` is invoked before `applicationDidFinishLaunching`. Because `openRepo` spawns an async `Task` (`Git.locate`), `controllers` is still empty when `applicationDidFinishLaunching` runs. Any rewrite of launch/restoration must track an `openedAtLaunch` / `inFlightOpens` flag synchronously in `openRepo` so `applicationDidFinishLaunching` never pops up `openDocument(nil)` (`NSOpenPanel.runModal()`) or restores unrelated `openRepos` on top of a cold URL launch.
2. **Same-repository worktree switching in `openRepo` (`main.swift:75-105`)**:
   - Opening a second worktree `W2` of an already-open repository must reuse the existing `RepoWindowController` window, update `home = W2`, persist the updated `openRepos` to `UserDefaults`, and wait for `Repository.refreshRefs` if the window is still in `start(spec:opening:)`. Canonicalizing `commonDir` with `Darwin.realpath` is essential so main and linked worktrees always match even when opened through symlinks or `/tmp`/`/var`.
3. **Bare-key shortcuts vs text editing across child panels and sheets (`WindowActions.swift:430-433`, `JumpActions.swift:7, 108-140`)**:
   - Twenty menu items use single-character key equivalents (`e`, `f`, `o`, `s`, `p`, `d`, `n`, `u`, `r`, `c`, `[`, `]`, `*`, `Shift+B/D/N/J/K/L/H/R/C`). If `validateMenuItem` disables them whenever a text field is focused, `Go to Anything` (`⌘K`) and the menu bar lose those commands when invoked from a search/filter field. Conversely, if `validateMenuItem` doesn't check `NSApp.keyWindow?.firstResponder`, child panels (`JumpPanel`, `RevisionSheet`) can have keystrokes intercepted by `NSApp.mainMenu`. The editable-text check must apply *only* during key-equivalent matching (`NSApp.currentEvent?.type == .keyDown`) and must inspect `NSApp.keyWindow?.firstResponder`.
4. **Menu validation side effects (`validateMenuItem` mutating `item.title` and `item.state`, `WindowActions.swift:436-463`)**:
   - `validateMenuItem` mutates `item.title` (`Show/Hide Navigator`, `Show/Hide Inspector`, `Mark File as Reviewed/Not Reviewed`, `Mark Change as Read/Unread`) and `item.state` (`Unified`, `Side by Side`, `Wrap Lines`, `Show Unchanged Lines`, `Show Unchanged Files`, `Blame`, `Zoom Pane`). Because `buildMainMenu()` creates hidden `alternate` `NSMenuItem`s sharing the same `action` selector (`main.swift:175-180`), and `enabledCommands` (`JumpActions.swift:114`) calls `validateMenuItem` to harvest command titles for `Go to Anything`, fast paths in `validateMenuItem` must still update `item.title` and `item.state` accurately before `JumpActions` reads `item.title`.
5. **Commit-level review state vs branch/worktree review state (`WindowActions.swift:144-148, 379-387`)**:
   - `RawChange.reviewKey` encodes `oldOid`, `oldMode`, `newOid`, `newMode`, `oldPath`, and `path`. In a multi-commit review, a file's whole-review `RawChange` (`mergeBase -> HEAD/worktree`) has different `oldOid`/`newOid` from an individual commit's `RawChange` (`c~1 -> c`) whenever the file was modified in more than one commit or in the working tree. Any fast path for `markCommit`, `markAllReviewed`, or commit progress badges in Step 3 must preserve or intentionally reconcile this distinction.
