# Argon Scoped Architecture & Efficiency Audit — Window Chrome, Looks, Panes & Themes

Scope:
- `Sources/SextantApp/Panes.swift` (`Session`, `Pane`, `PaneStrip`, `SeamlessSplitView`, `NSView.redrawSubtree`, `FlippedView`)
- `Sources/SextantApp/PaneCard.swift` (`PaneCard`)
- `Sources/SextantApp/Look.swift` (`LookChoice`, `Look`, `StripLayout`, `PaneHeaderStyle`, `WindowFrame`, `PaneSurface`, `NSSplitViewItem`, `NSView.pin`)
- `Sources/SextantApp/GlassLook.swift` (`GlassLook`, `GlassFrame`, `BackdropView`, `FrostWash`, `PillRowView`)
- `Sources/SextantApp/ClassicLook.swift` (`ClassicLook`, `Chrome`, `NSAppearance.isDark`, `ClassicFrame`, `FilledView`, `FrameBar`, `PaneColumn`, `ClassicRowView`, `Material`)
- `Sources/SextantApp/Titlebar.swift` (`SubjectControl`, `Titlebar`, `GoToAnythingField`)
- `Sources/SextantApp/StatusBar.swift` (`StatusBar`)
- `Sources/SextantApp/Theme.swift` (`Theme`, `Appearance`, `ThemedColors`, `NSColor.themed`, `NSImage.monochromeSymbol`)
- `Sources/SextantApp/Settings.swift` (`SettingsView`, `SettingsViewController`)
- `Sources/SextantApp/EmptyState.swift` (`EmptyState`)
- `Sources/SextantApp/ReviewHeader.swift` (`ReviewHeader`)
- Direct helpers/callers followed: `Sources/SextantCore/Strip.swift` (`stripOffset`), `Sources/SextantApp/ReviewSummary.swift` (`ReviewSummary`, `BaseChoices`), `Sources/SextantApp/PaneHeader.swift`, `Sources/SextantApp/RepoWindowController.swift`, `Sources/SextantApp/WindowActions.swift`, `Sources/SextantApp/Reader.swift`.

Benchmark & adversarial test harness:
- Package: `/Users/shrik450/Developer/review-ui/scratch/review/argon-sections/chrome`
- Rerun command:
  ```sh
  nix develop /Users/shrik450/Developer/review-ui -c swift run --package-path /Users/shrik450/Developer/review-ui/scratch/review/argon-sections/chrome -c release ChromeAuditBench
  ```
- Methodology: `SextantCore/Strip.swift`, `Contrast.swift`, and `Model.swift` are compiled directly from the repository sources; `@MainActor` AppKit chrome/theme/layout logic is extracted verbatim from the scope files into `ChromeAuditBench` and benchmarked against real AppKit views, menus, fonts, CoreGraphics paths, and graphics contexts, paired with exact source traces.

---

## 1. Architecture Overview

### Ownership & Data Flow
1. **Look & Frame (`Look.swift`, `GlassLook.swift`, `ClassicLook.swift`, `Titlebar.swift`, `StatusBar.swift`, `ReviewHeader.swift`)**:
   - `LookChoice` reads `"look"` from `UserDefaults` and vends a concrete `Look` (`GlassLook` or `ClassicLook`), which `RepoWindowController.init` captures once per window (`let look: any Look`).
   - `Look` is an abstract factory for window-level styling (`makeFrame() -> WindowFrame`, `makePaneSurface(content:header:) -> PaneSurface`, `makeRowView() -> NSTableRowView`, `floating(_:cornerRadius:)`, `panel(_:)`, `strip: StripLayout`, `paneHeader: PaneHeaderStyle`, `canvasOpacity(of:)`).
   - Data flows **into** `WindowFrame` via `frame.install(in: controller)` (once at window init), `frame.show(_ summary: ReviewSummary)` (called from `RepoWindowController.updateTitle()`), and `frame.columnsChanged()` (on `NSSplitView.didResizeSubviewsNotification`).
   - In `GlassLook`, `GlassFrame` places a `ReviewHeader` at the top of the `Navigator` sidebar and installs a unified `NSToolbar` whose control rects are queried by `PaneStrip.titlebarControls` during strip layout.
   - In `ClassicLook`, `ClassicFrame` sandwiches the 3-column `NSSplitView` vertically between a top `Titlebar` (containing `SubjectControl` and `GoToAnythingField`) and a bottom `StatusBar`.

2. **Sessions, Panes & Strip (`Panes.swift`, `PaneCard.swift`, `ClassicLook.swift:PaneColumn`, `Strip.swift`)**:
   - `Session` (`Panes.swift:5-33`) owns the loaded state of a `Review` (`resolved`, `changes: [FileState]`, `snapshotFiles: [String]`, `explored: [String: FileState]`, `definitions: [LocatedDefinition]?`, `indexTask: Task<Void, Never>?`), shared across every `Pane` viewing the same `Review`.
   - `Pane` (`Panes.swift:36-67`) pairs a `Reader` with its `PaneSurface` (`PaneCard` in Glass, `PaneColumn` in Classic), a reference to a `Session?`, `focus: Location.Place?`, and generation counters (`showGeneration`, `loadingGeneration`).
   - `PaneStrip` (`Panes.swift:76-220`) owns the horizontal scrolling viewport (`viewport -> track -> [PaneSurface]`). It sizes each pane to `paneWidth` (full width for 1 pane or when `isZoomed`, else `round(2/3 * area.width)` down to `minimumPaneWidth = 480`), computes `offset` via `stripOffset(...)` (`Strip.swift:16`), positions `track`, tells each `PaneSurface` which sub-rectangle `part` is visible inside the strip (`s.show(part:)`), and sets `s.headerClearance` to avoid overlapping `titlebarControls()`.
   - `PaneCard` and `PaneColumn` implement `show(part:)` by setting `clip.frame = part` and shifting `content.frame = NSRect(x: -part.minX, y: -part.minY, width: bounds.width, height: bounds.height)` so `CodeView` never rewraps when clipped at the strip edge.

3. **Themes, Appearance & Settings (`Theme.swift`, `Settings.swift`)**:
   - `Theme` is a value type holding `colors: [String: NSColor]` and `cardOpacity: CGFloat`.
   - `Appearance.shared` is a `@MainActor` singleton that loads built-in and user JSON themes (`~/.config/sextant/themes/*.json`), watches the filesystem (`FileWatcher`) and `UserDefaults.didChangeNotification`, updates `ThemedColors` (a global lock-protected cache of dynamic `NSColor(name:dynamicProvider:)` instances), and posts `Appearance.didChange`.
   - `SettingsView` is a SwiftUI form hosted in `SettingsViewController` that mutates `@AppStorage` keys (`look`, `lightTheme`, `darkTheme`, `fontName`, `fontSize`, `tabWidth`, `editorCommand`).

### What Is Duplicated or in the Wrong Place
- **`Session` lives in `Panes.swift` as a passive bag of mutable properties (`Panes.swift:5-33`)** while its lifecycle, diff loading, snapshot listing, and definition indexing are scattered across `RepoWindowController.swift` and `JumpActions.swift`. Because `Session` has no `deinit` or cancellation methods of its own, abandoning a `Session` leaks its running `indexTask`.
- **`PaneHeader` and `EmptyState` live inside `Reader.view` (`content`), which `PaneCard`/`PaneColumn` shift by `-part.minX` and clip to `part.width` (`PaneCard.swift:141-142`, `ClassicLook.swift:259-260`)**: clipping without rewrapping is right for `CodeView`, but wrong for `PaneHeader` and `EmptyState`, which must fit within the **visible** card `part`. `PaneStrip.clearance` tries to compensate for `PaneHeader` only when a toolbar control overlaps, and uses the unclipped `header` width `w` instead of `part`, causing peeking pane headers to be clipped off-screen on both left and right sides (Finding 1).
- **Double-dimming of unfocused pane headers (`PaneCard.swift:98` vs `PaneHeader.swift:179-189`)**: `PaneCard.applyEmphasis` dims all `content.subviews` (including `header`) to `alphaValue = 0.7` (or `0.5`), while `PaneHeader.applyEmphasis` simultaneously steps down its colors (`fg -> fgMuted`, `fgMuted -> fgSubtle`) and sets `stats.alphaValue = 0.5`.
- **Titlebar double-click action logic (`AppleActionOnDoubleClick`) is duplicated** between `FrameBar.mouseDown` (`ClassicLook.swift:168-172`) and `PaneHeader.mouseDown` (`PaneHeader.swift:171-175`), and `StatusBar` accidentally inherits it from `FrameBar` (Finding 10).
- **Window-scoped `Look` vs global `Appearance.defaultThemeName` (`Look.swift:4`, `RepoWindowController.swift:102`, `Theme.swift:367-370`)**: `Look` is per-window ("Applies to windows you open next"), but `Appearance` resolves default themes from the global `LookChoice.chosen` in `UserDefaults`, so flipping `Look` in Settings mutates the theme of already-open windows of the other look (Finding 9).

### Invariants Nothing Enforces
1. **Visible header & empty-state bounds invariant**: For every `PaneSurface` with `part.width >= 1`, `header`'s content (`12 + clearance.left .. bounds.width - 14 - clearance.right`) and `emptyState` must lie inside `[part.minX, part.maxX]`. Currently violated on both left-peeking and right-peeking cards (Finding 1, Finding 8).
2. **Strip docking invariant across resizes**: When `surfaces.count > 1` and `!isZoomed`, the focused pane must stay docked at either the leading or trailing edge of `paneArea` when `paneArea.width` (and thus `paneWidth`) changes. Currently violated by `stripOffset` comparing new `paneWidth` positions against an unscaled `offset` (Finding 8).
3. **Pane & Session teardown invariant**: Closing a `Pane` (`discard`) or replacing a `Session` must cancel all in-flight work owned by that pane/session (`Session.indexTask`, `Reader.analysis`, `Reader.pendingOccurrences`, `Pane.showGeneration`). Currently violated (Finding 3).
4. **Menu stability while open**: `updateTitle()` must never replace `NSPopUpButton.menu` while the user is interacting with it or when `BaseChoices` has not changed. Currently violated on every scroll file boundary and background refresh (Finding 2).

### How This Scope Fits the Plan's Target Design
- **Step 1 (Confirmed bugs)**: Fix peeking card header geometry (`PaneStrip.clearance`), `ReviewHeader` chevron dead click, `Titlebar.SubjectControl` truncation/dark-mode attributes, `StatusBar` double-click zoom, and `SettingsView.monospacedFamilies` false-positive proportional fonts (`"Arial Unicode MS"`).
- **Step 2 (Limits & lifetimes)**: Add `Session.deinit` cancellation for `indexTask`, cancel `Reader.analysis` / `pendingOccurrences` and invalidate `Pane.showGeneration` in `discard(_:)`, and bound `Session.explored` via Step 2's byte-bounded LRU.
- **Step 3 (Cheap UI fast paths)**: Remove `updateTitle()` from `readerCurrentFileChanged`, make `ReviewSummary` and `BaseChoices` `Equatable` with lazy `NSMenuDelegate` population for `base`, initialize `Appearance.lastSignature` in `init()`, cache `(light, dark)` `Theme` and `Style` on `Appearance`, cache `NSImage.monochromeSymbol`, guard `PaneCard.placeParts()` against no-op `CGPath` rebuilds, fix `PaneStrip` slide animations, and restrict `watchThemes()` to `themesDirectory` with `.json` filtering.

---

## 2. Ranked Findings

### Finding 1: Peeking pane headers in `PaneStrip` clip their titles and controls off-screen in both `GlassLook` and `ClassicLook`
- **Location**: `Sources/SextantApp/Panes.swift:175-182, 204-219`, `Sources/SextantApp/PaneCard.swift:141-142`, `Sources/SextantApp/ClassicLook.swift:259-260`
- **Classification**: Bug / Architecture (broken layout geometry on every multi-pane strip)
- **Plan step**: Step 1 / Step 3
- **Evidence (Code Trace + Benchmark `Test 1`)**:
  In `PaneCard.placeParts()` (`PaneCard.swift:141-142`) and `PaneColumn.placeParts()` (`ClassicLook.swift:259-260`), a partially visible neighbour pane clips `clip.frame = part` while keeping `content.frame = NSRect(x: -part.minX, y: -part.minY, width: bounds.width, height: bounds.height)` at the full unclipped `paneWidth` (`w = round(2/3 * area.width)`). Because `PaneHeader` is pinned to `content.leadingAnchor` and `content.trailingAnchor`, `PaneHeader` also has width `w` and origin `-part.minX` inside `clip`.
  Meanwhile, `PaneStrip.layoutPanes` (`Panes.swift:179-180`) passes the unclipped `header = NSRect(x: x, y: area.minY, width: w, height: self.headerHeight)` to `clearance(ofHeader:shownFrom:controls:)` (`Panes.swift:204-219`):
  ```swift
  let inWindow = convert(header, to: nil)
  let shownMinX = inWindow.minX + (shownFrom - header.minX)
  var leading: CGFloat = 0, trailing: CGFloat = 0
  for c in controls where c.maxY > inWindow.minY && c.minY < inWindow.maxY && c.maxX > shownMinX && c.minX < inWindow.maxX {
      if c.midX < (shownMinX + inWindow.maxX) / 2 {
          leading = max(leading, c.maxX + Self.controlClearance - inWindow.minX)
      } else {
          trailing = max(trailing, inWindow.maxX - c.minX + Self.controlClearance)
      }
  }
  ```
  This causes three simultaneous bugs whenever 2+ panes are open:
  1. **Right-peeking card in `GlassLook` (e.g., Pane 1 when Pane 0 is focused)**:
     Because `header.width` is the unclipped `w = 2/3 * area.width` instead of `part.width`, `inWindow.maxX` is `area.minX + 4/3 * area.width + gap`. Therefore, the midpoint `(shownMinX + inWindow.maxX) / 2` equals `area.maxX + gap` — which lies **to the right of the window's right edge** for every possible window width and sidebar width.
     Consequently, the right-hand `inspectorToggle` toolbar button (`c.midX < area.maxX + gap`) **always** satisfies `c.midX < (shownMinX + inWindow.maxX) / 2` and is misclassified as a **leading (left)** control on Pane 1!
     From `ChromeAuditBench` (`Test 1`, Case A — default `1440pt` window, `260pt` Navigator open, Pane 1 visible width `380pt`, unclipped width `776pt`):
     - `currentClearance` returns `left = 398.0pt, right = 0.0pt`.
     - `PaneHeader` places Pane 1's title at `x = 12 + 398 = 410.0pt` inside a `380.0pt` visible card — pushing Pane 1's entire header title and breadcrumbs `30pt` past the right edge of the visible card into the clipped-out region!
  2. **Left-peeking card when Navigator is open in `GlassLook`, or always in `ClassicLook` (e.g., Pane 0 when Pane 1 is focused)**:
     When the Navigator sidebar is open (`safe.left = 260`), the left toolbar buttons sit over the Navigator (`c.maxX = 210 <= shownMinX = 268`), and in `ClassicLook` `controls` is `[]`. No control matches `c.maxX > shownMinX`, so `clearance` returns `left = 0.0pt`.
     From `ChromeAuditBench` (`Test 1`, Case B — `part = (396, 0, 380, 884)`):
     - In `clip` coordinates (where `content.frame.origin.x = -396.0pt`), Pane 0's title sits at `x = 12 - 396 = -384.0pt` — **384pt to the left of `clip`**, completely invisible!
  3. **Right-peeking card trailing controls when Inspector is open in `GlassLook`, or always in `ClassicLook`**:
     Because `clearance.right` does not include `w - part.maxX` (`396pt`), the right-hand `stats` and buttons (`reviewedButton`, `splitButton`, `zoomButton`, `closeButton`) sit at `x ≈ 776pt` inside `content` while `clip` cuts off at `380pt`.
- **Fix**:
  Pass `part` into `clearance(ofHeader:part:controls:)`. Intersect `controls` against the **visible** header rect in window coordinates (`shownMinX = inWindow.minX + part.minX`, `shownMaxX = inWindow.minX + part.maxX`, midpoint `(shownMinX + shownMaxX) / 2`), and always include the clipped card overhangs `part.minX` and `inWindow.width - part.maxX`:
  ```swift
  private func clearance(ofHeader header: NSRect, part: NSRect, controls: [NSRect]) -> NSEdgeInsets {
      let rightClip = max(0, header.width - part.maxX)
      guard window != nil, part.width > 0 else {
          return NSEdgeInsets(top: 0, left: part.minX, bottom: 0, right: rightClip)
      }
      let shown = NSRect(x: header.minX + part.minX, y: header.minY, width: part.width, height: header.height)
      let inWindow = convert(shown, to: nil)
      var leading: CGFloat = 0, trailing: CGFloat = 0
      for c in controls where c.maxY > inWindow.minY && c.minY < inWindow.maxY && c.maxX > inWindow.minX && c.minX < inWindow.maxX {
          if c.midX < inWindow.midX {
              leading = max(leading, c.maxX + Self.controlClearance - inWindow.minX)
          } else {
              trailing = max(trailing, inWindow.maxX - c.minX + Self.controlClearance)
          }
      }
      return NSEdgeInsets(top: 0, left: part.minX + leading, bottom: 0, right: rightClip + trailing)
  }
  ```

---

### Finding 2: `updateTitle()` runs on every file boundary during Overview scroll and twice per `open()`, rebuilding the entire `NSPopUpButton` branch menu (`21.4 ms` at 10k branches, `350.4 ms` at 50k) and clobbering open menus
- **Location**: `Sources/SextantApp/ReviewSummary.swift:28-46, 58-76`, `Sources/SextantApp/ReviewHeader.swift:77-86`, `Sources/SextantApp/Titlebar.swift:37-49`, `Sources/SextantApp/ClassicLook.swift:123-127`, `Sources/SextantApp/RepoWindowController.swift:486, 640, 1072`
- **Classification**: Waste / Slowness / Bug
- **Plan step**: Step 3
- **Evidence (Code Trace + Benchmark `Test 4`)**:
  1. **Unnecessary calls**: `RepoWindowController.readerCurrentFileChanged(_:)` (`RepoWindowController.swift:1072`) calls `updateTitle()` every time scrolling crosses a file boundary in the Overview, and `open(_:at:in:)` calls `updateTitle()` at `:486` and again inside `present(_:at:in:)` at `:640`. Yet nothing in `window.title`, `ReviewSummary`, `ReviewHeader`, `Titlebar`, or `StatusBar` depends on `reader.currentFile` or the open file path (which is displayed in `PaneHeader`, not the window frame).
  2. **Superlinear `NSMenu` rebuild cost**: Every `updateTitle()` computes `reviewSummary` (filtering `repository.branches` 3 times and counting `changes.count(where: \.reviewed)`) and calls `BaseChoices.fill(base)` (`ReviewSummary.swift:28-46`), which builds a fresh `NSMenu` with an `NSMenuItem` for every local and remote branch and assigns `button.menu = menu`.
     From `ChromeAuditBench` (`Test 4`):
     | Branches | Eager `BaseChoices.fill(_:)` | 100 Overview file-boundary scrolls | Lazy `fillLazy` (first) | 100 repeat `updateTitle()` calls |
     |---:|---:|---:|---:|---:|
     | 100 | 0.135 ms | 13.46 ms | 19.79 µs | 1.21 µs |
     | 1,000 | 1.141 ms | 114.13 ms | 85.04 µs | 1.21 µs |
     | 10,000 | 21.386 ms | 2,138.65 ms | 803.62 µs | 1.50 µs |
     | 50,000 | 350.412 ms | 35,041.23 ms | 3,862.96 µs | 1.38 µs |
  3. **Live menu clobber bug**: Because `BaseChoices.fill(base)` unconditionally executes `button.menu = menu` on every `updateTitle()`, any background FSEvents `refresh()` or `statusChanged()` that fires while the user has the `Compared with` (`base`) popup menu open replaces the `NSMenu` out from under the open popup.
  4. **Duplicate branch item in `BaseChoices.fill(_:)`**: `fill(_:)` adds `usual` (e.g. `"main"`) at the top of `menu` (`ReviewSummary.swift:40`) and then adds all of `local` (`:41`) and `remote` (`:42`) without excluding `usual`, producing two `NSMenuItem`s with title `"main"` and `representedObject == "main"`.
- **Fix**:
  - Remove `updateTitle()` from `readerCurrentFileChanged(_:)` and the duplicate call in `open(_:at:in:)`.
  - Make `BaseChoices` and `ReviewSummary` conform to `Equatable`; cache `lastSummary: ReviewSummary?` in `ReviewHeader` and `ClassicFrame` so `show(_:)` is a no-op when unchanged.
  - Populate `base`'s full branch list lazily in `NSMenuDelegate.menuNeedsUpdate(_:)` when the user actually clicks the popup; until then, only set a single-item menu for `current` when `current` changes. Exclude `usual` (and `current`) from the `local`/`remote` sections or use `NSMenu` section items properly.

---

### Finding 3: Closing a `Pane` or switching `Session` fails to cancel `Session.indexTask`, `Reader.analysis`, and in-flight file loads, and `Session.explored` grows without bound
- **Location**: `Sources/SextantApp/Panes.swift:14, 26, 46-47`, `Sources/SextantApp/RepoWindowController.swift:493-506, 521, 750-755`, `Sources/SextantApp/Reader.swift:200`, `Sources/SextantApp/JumpActions.swift:31`
- **Classification**: Bug / Waste (leaked background tasks, retained view/text hierarchies, unbounded memory)
- **Plan step**: Step 2
- **Evidence (Code Trace)**:
  1. **`Session.indexTask` runs uncancelled after `Session` deallocation (`Panes.swift:26`, `JumpActions.swift:31`)**:
     `indexDefinitions(_ s: Session)` spawns `s.indexTask = Task(priority: .utility) { [weak self, weak s] in let found = try? await index.definitions(in: snapshot, git: git) ... }`. `Session` has no `deinit`, and neither `select(_:...)` (`RepoWindowController.swift:287`), `discard(_:)` (`:750`), nor `windowWillClose(_:)` (`:953`) cancels `s.indexTask`. Because `s` is captured weakly, when the last pane viewing `s` switches reviews or closes, `s` deallocates without cancelling `indexTask`, so `index.definitions(in: snapshot, git: git)` continues indexing the entire abandoned snapshot in the background.
  2. **Closed `Pane` keeps `Reader` alive and analyzing all shown files (`RepoWindowController.swift:750-755`, `Reader.swift:200`)**:
     ```swift
     private func discard(_ closed: [Pane]) {
         for p in closed {
             p.reader.delegate = nil
             p.surface.removeFromSuperview()
         }
     }
     ```
     `Reader.analyzeShownFiles()` (`Reader.swift:200`) starts `analysis = Task { ... }` which **strongly captures `self` (`Reader`)**. Because `discard(_:)` never cancels `p.reader.analysis` (or `p.reader.pendingOccurrences`), closing an Overview pane with 1,000 files keeps the closed `Reader` (including its `CodeView`, `NSTextStorage`, `NSLayoutManager`, and `[FileState]`) retained in memory while `analysis` loops through all 1,000 files on `@MainActor` and colors the dead `NSTextStorage`.
  3. **Closed `Pane` still renders in-flight `open()` loads and spawns `prepareNeighbors` (`RepoWindowController.swift:493-506`)**:
     `open(_:at:in:)` spawns a `Task` that strongly captures `p` and checks `guard gen == p.showGeneration else { return }`. Because `discard(_:)` does not increment `p.showGeneration` or nil out `p.session`, if `p` is closed while `fileState(...)` is awaiting git I/O, the completed `Task` still calls `present(f, at: anchor, in: p)` and `prepareNeighbors(of: path, in: s)` for the closed pane.
  4. **Unbounded `Session.explored: [String: FileState]` (`Panes.swift:14`, `RepoWindowController.swift:521`)**:
     Every non-changed file opened from the file tree, Go to Anything, Jump to Definition, or Find in Files is stored in `s.explored[path]` with its full `lines: [DiffLine]`, `tokens`, `definitions`, and `outline`, and is never evicted (for commit/branch/PR reviews, `s.explored` is never cleared for the life of the session).
- **Fix**:
  - Add `deinit { indexTask?.cancel() }` to `Session` in `Panes.swift`.
  - Add a `cancelTasks()` method on `Reader` (cancelling `analysis` and `pendingOccurrences`) and call `p.reader.cancelTasks(); p.showGeneration += 1; p.session = nil` inside `RepoWindowController.discard(_:)` and `windowWillClose(_:)`.
  - Bound `Session.explored` (or fold it into Step 2's byte-bounded O(1) LRU cache).

---

### Finding 4: `Appearance.init()` leaves `lastSignature = ""`, causing the first `UserDefaults` write during window/file open to fire a spurious `Appearance.didChange` that reloads every `Reader` and redraws the window
- **Location**: `Sources/SextantApp/Theme.swift:288-310`, `Sources/SextantApp/Reader.swift:108-122`, `Sources/SextantApp/RepoWindowController.swift:892-894`
- **Classification**: Bug / Waste (redundant full `Reader.reload` and window subtree redraw during launch/open, plus all hidden panes reloading on font size change)
- **Plan step**: Step 3
- **Evidence (Code Trace + Benchmark `Test 7B`)**:
  In `Appearance.init()` (`Theme.swift:288-310`):
  ```swift
  private init() {
      UserDefaults.standard.register(defaults: [
          LookChoice.defaultsKey: LookChoice.glass.rawValue,
          "fontSize": 12.0, "fontName": "", "diffMode": "unified", "tabWidth": 4,
      ])
      reloadThemes()
      watchThemes()
      observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.defaultsChanged() }
      })
  }
  private var lastSignature = ""
  ```
  1. `init()` calls `reloadThemes()`, leaving `lastSignature = ""`.
  2. When the first repository window opens and writes `"file"` to `"readerMode"` (`RepoWindowController.swift:481`), writes `"openRepos"` (`main.swift:136`), or autosaves window/split frames, `UserDefaults.didChangeNotification` invokes `defaultsChanged()`.
  3. Because `sig != ""` is `true`, `defaultsChanged()` calls `publishThemes()` and posts `Appearance.didChange` right after the initial file was rendered — forcing `Reader.appearanceChanged()` (`Reader.swift:121`) to run a second full `reload(keepPosition: true)` and `RepoWindowController.appearanceChanged` (`RepoWindowController.swift:893`) to run `window?.contentView?.redrawSubtree()` (`1.07 ms` at 10k views).
  4. Furthermore, whenever the user adjusts font size (`⌘+`/`⌘-`) or `tabWidth`:
     - `defaultsChanged()` calls `publishThemes()` and posts `Appearance.didChange`, causing `RepoWindowController` to call `redrawSubtree()` across the entire window chrome and sidebars (none of which use code `fontSize` or `tabWidth`).
     - Every `Reader` across all open `Pane`s in the strip — including off-screen panes with `surface.isHidden == true` — observes `Appearance.didChange` (`Reader.swift:108`) and synchronously executes `reload(keepPosition: true)` on the main thread in the same turn.
- **Fix**:
  - Replace `lastSignature: String` with an `Equatable` struct of the watched defaults, initialized in `Appearance.init()` **before** registering the `UserDefaults.didChangeNotification` observer.
  - Separate theme changes from code-style (`fontSize`, `fontName`, `tabWidth`) changes so font/tab changes only notify `Reader`s and do not call `publishThemes()` or `window?.contentView?.redrawSubtree()`.
  - In `Reader.appearanceChanged()`, if `view.window == nil || view.isHiddenOrHasHiddenAncestor`, mark a `needsStyleReload = true` flag and reload when the pane becomes visible in `PaneCard.show(part:)` / `PaneColumn.show(part:)`.

---

### Finding 5: `NSImage.monochromeSymbol` is uncached (`29.2x` slower per draw), and `Appearance.theme(for:)` / `Style.current(for:)` re-query `UserDefaults`, `LookChoice`, and `NSFontManager` on every call
- **Location**: `Sources/SextantApp/Theme.swift:360-377, 434-446`, `Sources/SextantApp/CodeView.swift:32-41`, `Sources/SextantApp/GlassLook.swift:197, 210, 216`, `Sources/SextantApp/ClassicLook.swift:271`, `Sources/SextantApp/PaneCard.swift:77`
- **Classification**: Waste / Slowness
- **Plan step**: Step 3
- **Evidence (Code Trace + Benchmark `Test 5C, 5D`)**:
  1. **`NSImage.monochromeSymbol` (`Theme.swift:434-446`)**:
     Called on every `TreeCell.configure` (`Cells.swift:126`) and inside `ProgressPie.draw(_:)` (`Cells.swift:270`) on every draw of a reviewed commit row. Each call looks up the base SF Symbol, applies `withSymbolConfiguration`, and allocates a brand-new `NSImage(size:flipped:drawingHandler:)`. Because the `NSImage` instance is never reused, AppKit's internal per-`NSImage` representation cache is thrown away on every call, forcing CoreGraphics to allocate a transparency layer, rasterize the vector glyph, and composite `.sourceAtop` on every draw.
     From `ChromeAuditBench` (`Test 5D`, 1,000 calls):
     - Create-only: **27.20 ms** (`27.2 µs/call`)
     - Uncached create + draw: **131.43 ms** (`131.4 µs/draw`)
     - Cached `NSImage` draw: **4.50 ms** (`4.5 µs/draw` — **29.2x speedup**)
  2. **`Appearance.shared.theme(for:)` (`Theme.swift:360-364`)**:
     Called in `PillRowView.drawSelection`, `ClassicRowView.drawSelection`, `PaneCard.updateLayer`, `FrostWash.updateLayer`, and `Style.current(for:)`. Every call runs `bestMatch(from: [.aqua, .darkAqua])`, queries `UserDefaults` for `"darkTheme"`/`"lightTheme"`, falls back to `Self.defaultThemeName(dark:)` (which queries `UserDefaults` for `"look"` and constructs `GlassLook()`/`ClassicLook()`), linearly scans `themes`, and copies `Theme` (`[String: NSColor]`).
     From `ChromeAuditBench` (`Test 5C`, 10,000 calls):
     - Uncached `theme(for:)`: **6.96 ms** vs cached `(light, dark)` theme property: **1.71 ms** (**4.1x speedup**).
     - Also, `PillRowView.drawSelection` (`GlassLook.swift:210, 216`) resolves `let theme = Appearance.shared.theme(for: effectiveAppearance)` on line 210 and then calls `NSColor.themed("fg").withAlphaComponent(0.08)` on line 216 instead of `theme.fg.withAlphaComponent(0.08)`.
  3. **`Style.current(for:)` (`CodeView.swift:32-41`)**:
     Queries `UserDefaults` for `"fontSize"`, `"fontName"`, `"tabWidth"`, converts the font via `NSFontManager.shared.convert(_:toHaveTrait:.boldFontMask)`, and measures `"0"` via `("0" as NSString).size(withAttributes:)` on every call (**8.18 ms** per 1,000 calls; `8.18 µs/call`).
- **Fix**:
  - Cache resolved `lightTheme` and `darkTheme` (and `lightStyle` / `darkStyle`) on `Appearance.shared`, updating them only when `reloadThemes()` or `defaultsChanged()` runs.
  - Cache `NSImage.monochromeSymbol` in a dictionary keyed by symbol name, configuration, and color (since `NSColor.themed(...)` is dynamic, the same `NSImage` works across light and dark appearances; clear the image cache in `ThemedColors.use(light:dark:)` so custom theme switches re-render cached symbol reps).
  - Use `theme.fg.withAlphaComponent(0.08)` in `PillRowView.drawSelection` (`GlassLook.swift:216`).

---

### Finding 6: `SettingsView.monospacedFamilies` blocks the main thread for `144 ms` and offers proportional fonts like `"Arial Unicode MS"` as code fonts
- **Location**: `Sources/SextantApp/Settings.swift:14-17`
- **Classification**: Slowness / Bug
- **Plan step**: Step 1 / Step 3
- **Evidence (Code Trace + Benchmark `Test 5E`)**:
  ```swift
  private static let monospacedFamilies: [String] = NSFontManager.shared.availableFontFamilies.filter { fam in
      guard let f = NSFont(name: fam, size: 12) else { return false }
      return f.isFixedPitch || fam.localizedCaseInsensitiveContains("mono") || fam.localizedCaseInsensitiveContains("code")
  }
  ```
  1. **144 ms synchronous main-thread stall**: Evaluating `SettingsView.monospacedFamilies` instantiates `NSFont(name: fam, size: 12)` and reads the `post` table (`isFixedPitch`) for all 181 installed font families on the main thread, taking **144.11 ms** in `ChromeAuditBench` (`Test 5E`).
  2. **False-positive proportional fonts**: Because `"Unicode"` contains the substring `"code"`, `fam.localizedCaseInsensitiveContains("code")` matches **`"Arial Unicode MS"`** (where 10 `"i"`s measure `26.7pt` and 10 `"W"`s measure `113.3pt` — a `4.2x` width ratio!), as well as any proportional font with `"Code"` or `"Mono"` in its family name (e.g. `"Encode Sans"`, `"Monotype Corsiva"`). Selecting such a font in Settings breaks `CodeView`'s fixed-pitch `digitWidth` assumptions for tab stops and column math.
- **Fix**:
  Verify fixed pitch by comparing glyph advance widths (e.g. `abs(f. advancement(forGlyph: iGlyph).width - f.advancement(forGlyph: wGlyph).width) < 0.01`) or querying CoreText `CTFontCollection` with `kCTFontMonoSpaceTrait`, and compute the list asynchronously or on background launch warmup.

---

### Finding 7: `PaneStrip` and `PaneCard` slide animations fail to animate on `branch()`, hide outgoing panes at `t = 0`, snap shadows at `t = 0`, and double-dim unfocused headers
- **Location**: `Sources/SextantApp/Panes.swift:183-195`, `Sources/SextantApp/PaneCard.swift:93-112, 139-158`, `Sources/SextantApp/ClassicLook.swift:257-261`, `Sources/SextantApp/RepoWindowController.swift:698-711`
- **Classification**: Bug / Waste
- **Plan step**: Step 3
- **Evidence (Code Trace + Benchmark `Test 3, Test 7A`)**:
  1. **`branch()` never animates the strip slide (`Panes.swift:183`, `RepoWindowController.swift:698-711`)**:
     In `PaneStrip.layoutPanes(animated:)` (`Panes.swift:183`), the animation block is guarded by:
     ```swift
     if animated, track.frame.size == trackFrame.size {
     ```
     Whenever a pane is opened (`branch()`) or closed (`closePane()`), `surfaces.count` changes, which changes `total` and therefore `trackFrame.size.width` (`1164pt -> 1560pt -> 2344pt` in `Test 7A`). Thus `track.frame.size == trackFrame.size` is **always `false`** when opening or closing a pane, so the `else` branch runs and snaps `track.frame = trackFrame` without animation!
     In addition, `RepoWindowController.branch()` (`RepoWindowController.swift:705-709`) calls `showNotes()` and `showPanes(animated: true)`, and then immediately calls `paneFocusChanged()`, which calls `showPanes(animated: true)` and `showNotes()` a second time in the same event turn.
  2. **Outgoing panes vanish at `t = 0` (`PaneCard.swift:140`, `ClassicLook.swift:258`)**:
     During `focusPane` (when `track.frame.size == trackFrame.size` is true), `place()` runs at the start of the animation with the **target** `trackFrame.minX`. For any pane whose post-slide `part.width` is `0` (e.g. the outgoing pane when `isZoomed == true`, or when jumping 2 panes over), `placeParts()` sets `isHidden = part.width < 1` (`true`) immediately at `t = 0`, making the outgoing pane vanish on frame 0 instead of sliding out of view.
  3. **Card shadow and cutout snap at `t = 0` (`PaneCard.swift:144-157`)**:
     Inside `PaneCard.placeParts()`, `CATransaction.setDisableActions(true)` disables implicit animations on `cardShadow.frame`, `cardShadow.shadowPath`, `shadowCutout.frame`, and `shadowCutout.path`, so the shadow and cutout jump to their final post-slide rect at `t = 0` while `track` and `clip` animate over `0.18s`.
  4. **Redundant `CGPath` and `CATransaction` rebuilds (`PaneCard.swift:139-158`)**:
     `show(part:)` and `layout()` call `placeParts()` unconditionally even when `part`, `bounds.size`, and `cardShadow.shadowRadius` are unchanged (and even when `isHidden == true`), allocating two `CGPath`s and invalidating `CAShapeLayer` mask caches on every call (`8.75 ms` per 10k calls unguarded vs `0.16 ms` guarded in `Test 3`).
  5. **Double-dimming and group-opacity offscreen pass on unfocused `PaneCard`s (`PaneCard.swift:98` vs `PaneHeader.swift:179-189`)**:
     `PaneCard.applyEmphasis` sets `v.animator().alphaValue = 0.7` (or `0.5`) on all `content.subviews` (including `header` and `stack`), while `PaneHeader.applyEmphasis` also dims its colors (`fg -> fgMuted`, `fgMuted -> fgSubtle`, `stats.alphaValue = 0.5`), resulting in compounded dimming on `PaneHeader` (`stats` alpha `0.35` / `0.25`) and forcing CoreAnimation group-opacity offscreen rendering on `stack`. Furthermore, when `animated == false`, `PaneCard.applyEmphasis` still creates an `NSAnimationContext` group and calls `v.animator().alphaValue` instead of setting `v.alphaValue` directly.
- **Fix**:
  - In `PaneStrip.layoutPanes`, resize `track.frame.size = trackFrame.size` without animation before animating `track.animator().frame.origin = trackFrame.origin` (when `animated && bounds.width > 0`), and remove the duplicate `showNotes()` / `showPanes(animated: true)` calls in `RepoWindowController.branch()`.
  - Keep panes with prior `part.width >= 1` visible (`isHidden = false`) during the slide animation and hide off-screen panes upon completion.
  - Guard `PaneCard.placeParts()` on `(part, bounds.size, cardShadow.shadowRadius)` actually changing, and skip shadow `CGPath` creation when `part.width < 1`.
  - When `!animated` in `PaneCard.applyEmphasis`, set `v.alphaValue = alpha` directly without `v.animator()`, and exclude `header` from `content.subviews` alpha dimming since `PaneHeader.applyEmphasis()` already dims unfocused headers.

---

### Finding 8: `stripOffset` drifts during window/sidebar resize when 3+ panes are open, and `EmptyState` is sliced in half on peeking panes
- **Location**: `Sources/SextantCore/Strip.swift:16-23`, `Sources/SextantApp/Panes.swift:173`, `Sources/SextantApp/Reader.swift:100-102`
- **Classification**: Bug (layout geometry)
- **Plan step**: Step 3
- **Evidence (Code Trace + Benchmark `Test 2`)**:
  1. **Viewport resize drift in `stripOffset` (`Strip.swift:16-23`)**:
     ```swift
     public func stripOffset(showing index: Int, from offset: CGFloat, paneWidth: CGFloat, gap: CGFloat, viewport: CGFloat, total: CGFloat) -> CGFloat {
         let minX = CGFloat(index) * (paneWidth + gap), maxX = minX + paneWidth
         var o = offset
         if minX < o { o = minX }
         if maxX > o + viewport { o = maxX - viewport }
         return max(0, min(o, max(0, total - viewport)))
     }
     ```
     Because `paneWidth = (area.width * 2 / 3).rounded()` changes whenever `viewport` (`area.width`) changes, `minX` and `maxX` scale with `viewport`, whereas the stored `offset` in `PaneStrip` does not.
     From `ChromeAuditBench` (`Test 2`, 3 panes, `focused = 1`):
     - Focusing Pane 1 from Pane 0 at `V1 = 900pt` (`w1 = 600pt`) docks Pane 1 flush with the right edge (`offset = 308pt`), with Pane 0 peeking on the left (`[0..292pt]`) and Pane 2 off-screen (`[908..1508pt]`).
     - Narrowing the viewport to `V2 = 810pt` (`w2 = 540pt`) gives `minX = 548 >= 308` and `maxX = 1088 <= 308 + 810 = 1118`. Neither clamp fires, so `offset` remains `308pt` — leaving Pane 1 floating at `[240..780pt]` while a **`22pt` sliver of Pane 2** leaks into the right edge (`[788..810pt]`) and `232pt` of Pane 0 shows on the left!
     - Conversely, docking Pane 1 on the left at `810pt` (`offset = 548pt`) and widening to `900pt` leaves `offset = 548pt`, leaking a **`52pt` sliver of Pane 0** on the left while Pane 2 shows on the right.
  2. **`EmptyState` sliced in half on peeking panes (`Reader.swift:100-102`)**:
     `emptyState.centerXAnchor` is constrained to `stack.centerXAnchor` (`w / 2` in unclipped `content` coordinates). In a peeking pane, `part.width` is `~1/3 * area.width = w / 2`, so `x = w / 2` is the exact cut edge of `clip`, slicing `EmptyState`'s icon and label vertically down the middle.
- **Fix**:
  - Scale `offset` proportionally when `paneWidth` changes (`offset = (offset / oldStride * newStride).rounded()`) before calling `stripOffset`, or record whether `focused` is docked at the leading or trailing edge of the viewport.
  - Center `emptyState` within the visible horizontal region of the pane (or offset its `centerXAnchor` by `(part.minX - (bounds.width - part.maxX)) / 2`).

---

### Finding 9: User themes load in filename order instead of `base` dependency order, `watchThemes()` never stops watching `$HOME` and fires `Appearance.didChange` on non-JSON files, and `Look` changes mutate open windows' themes
- **Location**: `Sources/SextantApp/Theme.swift:56-68, 251-263, 303, 317-370`, `Sources/SextantApp/Settings.swift:28, 82-85`
- **Classification**: Bug / Waste / Architecture
- **Plan step**: Step 3
- **Evidence (Code Trace + Benchmark `Test 5A, 5B`)**:
  1. **Alphabetical filename order breaks `base` inheritance (`Theme.swift:251-263, 344`)**:
     `reloadThemes()` loads `*.json` files sorted by `lastPathComponent` in a single pass, resolving `"base"` only against `bases: result` loaded so far (`Theme.swift:255`).
     In `ChromeAuditBench` (`Test 5B`), when `a_child.json` specifies `"base": "Parent Theme"` defined in `b_parent.json`, `"Parent Theme"` is not yet in `result`, so `"Child Theme"` silently falls back to `Theme.revueDark` instead of inheriting `"Parent Theme"`'s colors!
  2. **Theme watcher stays on `$HOME` after `createThemesDirectory` and reloads on `.DS_Store` / `.disabled` (`Theme.swift:317-338`)**:
     In addition to the known finding that `watchThemes()` walks up to `$HOME` when `~/.config/sextant/themes` doesn't exist:
     - `createThemesDirectory(example:)` (`:330-338`) creates the directory and writes `example.json.disabled`, but never re-invokes `watchThemes()` to narrow `themeWatcher` from `$HOME` to `themesDirectory`.
     - The watcher filter `paths.contains(where: { $0.hasPrefix(dir) })` (`:322`) lacks a trailing `/` (matching sibling paths like `themes-backup`) and does not check `.hasSuffix(".json")`, so creating `example.json.disabled` or Finder writing `.DS_Store` triggers synchronous `reloadThemes()` on `@MainActor`, which unconditionally posts `Appearance.didChange` even when `themes` is unchanged.
  3. **Changing `Look` in Settings mutates existing windows' default themes (`Theme.swift:303, 367-370`, `Settings.swift:28`)**:
     `Settings.swift:28` states `Look` `"Applies to windows you open next"`, and `RepoWindowController` keeps its initial `look`. Yet `Appearance.defaultThemeName(dark:)` reads `LookChoice.chosen.look.defaultThemes` from `UserDefaults`, and `defaultsChanged()` watches `LookChoice.defaultsKey`. Switching `Look` from `Glass` to `Classic` in Settings immediately switches an open `GlassLook` window's default theme to `GitHub Dark`/`Light` (`cardOpacity = 1.0`), turning its translucent glass cards opaque.
  4. **Deleted custom theme breaks SwiftUI `Picker` selection (`Settings.swift:82-85`, `Theme.swift:363`)**:
     If a user's stored `lightTheme`/`darkTheme` JSON file is deleted or renamed, `SettingsView.theme(_:dark:)` still binds the `Picker` to the missing theme name (which is absent from `themes`), causing an invalid SwiftUI `Picker` selection, while `Appearance.theme(for:)` (`:363`) falls back to `Theme.revueDark`/`revueLight` instead of `Self.defaultThemeName(dark:)`.
  5. **`Theme.parse` accepts `"+12345"` and allocates per token (`Theme.swift:56-68`)**:
     `Theme.parse` trims with `CharacterSet.whitespaces`, mutates a `String`, and calls `UInt64(s, radix: 16)`, which accepts a leading `+` (`Theme.parse("+12345")` returns a non-nil `NSColor` in `Test 5A`) and takes `14.96 ms` vs `4.53 ms` (**3.3x slower**) than a direct UTF-8 byte parser across 100k tokens.
- **Fix**:
  - Parse user theme JSON dictionaries first, then resolve `base` references across all user and built-in themes (with a cycle guard), and only post `Appearance.didChange` when `themes` actually changes.
  - Only start `themeWatcher` on `themesDirectory` when it exists (and start it in `createThemesDirectory`), canonicalize with `realpath`, and filter events to `path.hasPrefix(dir + "/") && path.hasSuffix(".json")`.
  - Resolve default theme names from the window's own `look` (or fall back to `defaultThemeName(dark:)` when a stored theme name is missing in both `Appearance.theme(for:)` and `SettingsView.theme(_:dark:)`).
  - Use a direct UTF-8 hex byte parser in `Theme.parse`.

---

### Finding 10: `ReviewHeader`'s chooser chevron is a dead click zone, `Titlebar.SubjectControl` drops middle-truncation and dark-mode color on `attributedTitle`, and double-clicking `StatusBar` zooms/minimizes the window
- **Location**: `Sources/SextantApp/ReviewHeader.swift:11, 51`, `Sources/SextantApp/Titlebar.swift:17, 37-43, 127-131`, `Sources/SextantApp/ClassicLook.swift:165-173`, `Sources/SextantApp/StatusBar.swift:6`
- **Classification**: Bug (UI correctness)
- **Plan step**: Step 1 / Step 3
- **Evidence (Code Trace + Benchmark `Test 7C`)**:
  1. **`ReviewHeader` chevron dead click (`ReviewHeader.swift:11, 51`)**:
     `ReviewHeader` places `subject: NSButton` and `chooser = NSImageView(image: NSImage(systemSymbolName: "chevron.up.chevron.down", ...)!)` side by side in `subjectRow = NSStackView(views: [subject, chooser])`. `chooser` has no click handler and `ReviewHeader` does not override `hitTest(_:)`. As verified in `ChromeAuditBench` (`Test 7C`), `subjectRow.hitTest(chooserCenter)` returns `NSImageView` (`hitView === subjectButton` is `false`), so clicking the dropdown chevron next to the subject title in `GlassLook` does nothing!
  2. **`Titlebar.SubjectControl` truncation & dark-mode bug (`Titlebar.swift:17, 37-43, 127-131`)**:
     In `SubjectControl.init()`, `subject.lineBreakMode = .byTruncatingMiddle` is set (`:17`). However, `SubjectControl.show(_:base:)` (`:38-42`) assigns `subject.attributedTitle = text` with attributes `[.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]` and a trailing `NSTextAttachment` chevron — omitting both `.paragraphStyle` and `.foregroundColor` (`Test 7C`). In AppKit, an `NSButton` `attributedTitle` without a paragraph style ignores `button.lineBreakMode` (clipping off the trailing chevron when `s.title` exceeds `320pt` instead of middle-truncating the title), and without `.foregroundColor` fails to follow active/inactive titlebar dimming (`Titlebar.activityChanged()` at `:127-131` only dims `title`, `navigatorButton`, and `inspectorButton`, leaving `subject` and `goToAnything` undimmed).
  3. **Double-clicking `StatusBar` zooms/minimizes the window (`StatusBar.swift:6`, `ClassicLook.swift:165-173`)**:
     `StatusBar` subclasses `FrameBar`, which overrides `mouseDown(with:)` (`ClassicLook.swift:165-173`) to perform `AppleActionOnDoubleClick` (`performZoom` / `performMiniaturize`). Double-clicking the bottom status bar zooms or minimizes the window like a titlebar.
- **Fix**:
  - In `ReviewHeader`, override `hitTest(_:)` so hits on `chooser` return `subject` (just as `Titlebar.hitTest` at `Titlebar.swift:121-124` returns `self` for `title`), or make `chooser` a button targeting `subject`.
  - In `SubjectControl`, replace the `attributedTitle` attachment with a separate chevron view (like `ReviewHeader`) so `subject.title` uses native `.byTruncatingMiddle` and `contentTintColor`, and update `SubjectControl` / `GoToAnythingField` alpha or tint in `Titlebar.activityChanged()`.
  - Restrict double-click zoom/minimize in `FrameBar.mouseDown(with:)` to `edge == .minY` (`Titlebar`).

---

## 3. Correctness Edge Cases That a Performance Rewrite Could Break

1. **Main-window emphasis permanence when a child panel/popover has key focus (`PaneCard.swift:73, 94, 118-122`, `ClassicLook.swift:180-195`)**:
   - `PaneCard` and `FrameBar` intentionally observe `NSWindow.didBecomeMainNotification` / `didResignMainNotification` (`window.isMainWindow`), **not** `didBecomeKeyNotification` / `didResignKeyNotification`.
   - When `JumpPanel` (Go to Anything, a child `NSPanel`), `SubjectPicker` (`NSPopover`), `NoteEditor`, or `Peek` opens and becomes the `keyWindow`, the repo window **remains the `mainWindow`**. Any rewrite that conflates key-window state with main-window state will cause all `PaneCard`s and `FrameBar`s to flash/dim whenever Go to Anything or a popover opens.
2. **Shadow cutout mask on translucent `PaneCard`s (`PaneCard.swift:10-12, 48-50, 146-155`)**:
   - Because `GlassLook` cards have `cardOpacity < 1.0` (`0.9` in `Revue Dark`, `0.95` in `Revue Light`), a standard layer shadow on `clip.layer` would paint **underneath the card's own interior** and darken `canvasFill` through its translucency.
   - `cardShadow` is a sibling layer masked by `shadowCutout` with `fillRule = .evenOdd` (an outer rect inset by `-reach` minus the inner rounded card rect) so the shadow is cast strictly outside the card perimeter. Caching or simplifying `PaneCard` shadow paths in Step 3 must preserve this exterior-only cutout geometry whenever `part.size` or `cardShadow.shadowRadius` changes.
3. **CodeView width stability during strip sliding and peeking (`PaneCard.swift:141-142`, `ClassicLook.swift:259-260`)**:
   - When a pane peeks at the edge of `PaneStrip`, `clip.frame` shrinks to `part.width` (`~1/3` of the strip), while `content.frame.size.width` **must remain `bounds.width` (`paneWidth`, `~2/3` of the strip)**.
   - If a rewrite pins `content` to `clip` (resizing `content.frame.width` to `part.width`), `CodeView` will re-layout and re-wrap every line of code when a pane becomes a peeking neighbour or during a slide animation. Only the chrome overlays (`PaneHeader` via `clearance`, and `EmptyState`) should adapt to `part`; `CodeView`'s width must stay `paneWidth`.
4. **Dynamic `NSColor.themed` resolution across split/multi-display appearances (`Theme.swift:393-414`)**:
   - `ThemedColors.color(_:)` returns an `NSColor(name:dynamicProvider:)` that resolves its token against `NSAppearance.currentDrawingAppearance` at draw/layout time.
   - Caching resolved `CGColor`s globally instead of per-`NSAppearance` (or forgetting to invalidate `NSImage.monochromeSymbol` representations when `ThemedColors.use(light:dark:)` swaps themes within the same `.aqua`/`.darkAqua` appearance) will leave stale theme colors on screen after switching themes in Settings.
5. **Safe-area insets on `PaneStrip` (`Panes.swift:135-139, 164`, `GlassLook.swift:86`)**:
   - In `GlassLook`, `stripItem.automaticallyAdjustsSafeAreaInsets = true` allows `PaneStrip` to extend underneath the floating `Navigator` sidebar so `BackdropView` is continuous, while `PaneStrip.paneArea` uses `safeAreaInsets.left` and `safeAreaInsets.right` to keep panes clear of the floating sidebar and **ignores `safeAreaInsets.top`** so card headers share the top row with the traffic lights and toolbar buttons. Changing how `safeAreaInsets` are applied to `PaneStrip` or `viewport` will either shove cards below the titlebar in `GlassLook` or tuck the focused card underneath the floating `Navigator`.
