# Scoped Architecture & Efficiency Audit: Sidebars & Lists (`Navigator.swift`, `Inspector.swift`, `PaneHeader.swift`, `JumpPanel.swift`, `NotesPane.swift`, `NoteEditor.swift`, `Cells.swift`, `ChangeCounter.swift`)

Scope: `Sources/SextantApp/Navigator.swift`, `Inspector.swift`, `PaneHeader.swift`, `JumpPanel.swift`, `NotesPane.swift`, `NoteEditor.swift`, `Cells.swift`, `ChangeCounter.swift` (following calls into `Sources/SextantApp/RepoWindowController.swift`, `WindowActions.swift`, `JumpActions.swift`, `Reader.swift`, `Document.swift`, `ReviewStore.swift`, `Notes.swift`, `Look.swift`, `GlassLook.swift`, `ClassicLook.swift`, `Theme.swift`, and `Sources/SextantCore/FileTree.swift`, `Outline.swift`, `Jump.swift`, `Reading.swift`).

To reproduce all microbenchmarks and adversarial verification tests in this report:
```sh
cd /Users/shrik450/Developer/review-ui/scratch/review/argon-sections/sidebars
nix develop /Users/shrik450/Developer/review-ui -c swift build -c release
./.build/release/SidebarsAuditBench
```
Core functions (`fileTree`, `outline`, `changeRuns`, `changeOrdinal`, `rankFuzzy`, `fuzzyScore`, `ReadingState`, `RawChange`) are compiled directly from `Sources/SextantCore/*.swift` via `SextantSidebarsCore`; AppKit table/outline/cell behaviors and controller logic are tested and benchmarked against real AppKit instances (`NSOutlineView`, `NSTableView`, `NSTextField`, `NSPopUpButton`, `IndexSet`) in `SidebarsAuditBench`.

---

## 1. Architecture Overview & Target Design Fit

### Ownership and Data Flow
- **`Navigator` (`Navigator.swift:22`)**: Left sidebar `NSViewController`. Owns the optional `heading: NSView?` (`ReviewHeader` in `GlassLook`), the `Changes`/`Find` segmented control, and two child controllers:
  - **`ChangesController` (`Navigator.swift:114`)**: Owns `commits: KeyTableView` (upper split pane) and `outline: KeyOutlineView` + `filter: NSSearchField` + `mode: NSSegmentedControl` (lower split pane).
    - **Inputs**: `setScopes(_:selected:)`, `setFiles(_:paths:)`, `refreshReviewState()`, `refreshCommitProgress()`, `showFocus(_:)`, and `reviews: ReviewStore?`.
    - **Outputs**: `NavigatorDelegate` callbacks (`navigatorSelectScope`, `navigatorOpen`, `navigatorShowOverview`, `navigatorToggleReviewed`, `navigatorFileMenu`, `navigatorCommitMenu`, `navigatorFocusReader`).
  - **`SearchController` (`Navigator.swift:505`)**: Owns `field: NSSearchField`, `outline: KeyOutlineView`, and the floating `footer` status pill.
    - **Inputs**: `begin(_:word:)`, `show(_:title:definitions:capped:)`, `summary`.
    - **Outputs**: `navigatorSearch(_:word:caseSensitive:)`, `navigatorOpenResult(path:line:)`, `navigatorFocusReader()`.
- **`Inspector` (`Inspector.swift:17`)**: Right sidebar `NSViewController`. Owns `outline: KeyOutlineView` (upper split pane) and `notes: NotesPane` (lower split pane), backed by an `Entry` tree rooted at `root`.
  - **Inputs**: `showFile(_:card:)`, `showOverview(_:card:)`, `showEmpty(card:)`, `updateCard(_:)`, `refreshReviewState()`, `follow(lineIndex:)`, and `isRead: (FileState, FileState.KeyedRun) -> Bool`.
  - **Outputs**: `InspectorDelegate` (`inspectorJump(toLineIndex:)`, `inspectorShowChange(_:)`).
- **`NotesPane` (`NotesPane.swift:17`) & `NoteEditor` (`NoteEditor.swift:7`)**:
  - `NotesPane` owns `table: KeyTableView`, header controls (`count`, `add`, `copyAll`), `empty: EmptyState`, and `notes: [Note]`. Communicates via `NotesPaneDelegate`.
  - `NoteEditor` is a transient `NSPopover` controller owning an `NSTextView` inside `NoteTextBox` for creating/editing/deleting a line or review note.
- **`PaneHeader` (`PaneHeader.swift:10`) & `ChangeCounter` (`ChangeCounter.swift:9`)**:
  - `PaneHeader` sits at the top of each `Reader` pane, owning the jump-bar buttons (`title`, `folders: NSStackView`, `symbols: NSPopUpButton`), `stats: NSTextField`, and action buttons (`reviewedButton`, `splitButton`, `zoomButton`, `closeButton`), plus `tree: [String]` (`s.snapshotFiles`).
  - `ChangeCounter` floats at the bottom center of the focused `Reader` pane, displaying the current 1-based change ordinal and `previous`/`next` buttons.
- **`JumpPanel` (`JumpPanel.swift:22`)**: Borderless floating `NSPanel` for Go to Anything (`⌘K`), owning `field: NSTextField`, `table: NSTableView` of `JumpCell`s, `status: NSTextField`, and an in-flight `searching: Task<Void, Never>?`.
- **`Cells.swift`**: Shared table/outline subclasses (`KeyTableView`, `KeyOutlineView`), cell views (`TreeCell`, `TargetCell`, `CommitCell`, `ProgressPie`), `fileIcon(_:)`, and `compactDate(_:)`.

### What Is in the Wrong Place or Duplicated
1. **`ChangesController` rebuilds its entire model and `FileNode` -> `Item` tree on every review toggle, filter keystroke, and pane switch (`Navigator.swift:281-287, 320-348`, `RepoWindowController.swift:542`)**:
   - `fileTree(...)` in `SextantCore` allocates an intermediate `Folder` trie, sorts every folder's keys with `localizedStandardCompare`, builds a value-type `[FileNode]` tree, and `ChangesController.rebuild()` immediately copies `[FileNode]` into a parallel reference-type `[Item]` tree (`Navigator.swift:340-348`).
   - Toggling a single file's reviewed state (`refreshReviewState()`) only changes `reviewed: Int` on that file's `Item` and its ancestor folder `Item`s (plus `All Changes`), yet `refreshReviewState()` calls `rebuild()`, reconstructing the entire 300k-path tree and calling `outline.reloadData()`.
   - Switching between two panes sharing the same `Session` calls `bindSideColumns()` -> `navigator.changes.setFiles(s.changes, paths: s.snapshotFiles)` (`RepoWindowController.swift:542`), which has no equality check and rebuilds the tree even when `changes` and `paths` are identical.
2. **File-filter ranking (`ChangesController.filter`) duplicates `JumpPanel` fuzzy ranking synchronously on `@MainActor` without caching or cancellation (`Navigator.swift:322-324`)**:
   - On every keystroke (`sendsSearchStringImmediately = true`), `rebuild()` constructs `Array(Set(paths).union(byPath.keys))` (hashing 300k strings on the main thread even though `paths` is already sorted and deduplicated) and runs `rankFuzzy(query, all)` synchronously on the main actor.
   - Worse, while `!query.isEmpty`, every `refreshReviewState()` (e.g. pressing Space to mark a filtered result reviewed) re-runs `Set(paths)` + `rankFuzzy` over all 300k paths on the main thread.
3. **`Inspector.updateCard` triggers a full `rebuild()` + `follow(lineIndex:)` on every caret move when Blame is active (`Inspector.swift:176-204`, `RepoWindowController.swift:720-722`)**:
   - `readerCaretMoved` calls `inspector.follow(lineIndex:)` and then, when `blameOn == true`, `inspector.updateCard(card())`.
   - `updateCard` calls `rebuild()`, which recomputes the entire `"Changes"` section (including `flatten(items)` and $O(R \cdot S)$ enclosing-symbol lookups), recomputes the `"Outline"` section, runs `merge`, reconfigures all available row views, scans all rows for `.card`, and calls `follow(lineIndex:)` a second time—all when only the blame card text at the bottom of the inspector changed.
4. **`PaneHeader` stores a copy of `tree: [String]` (`snapshotFiles`) per pane and linearly scans it twice on folder click (`PaneHeader.swift:19, 290-343`)**:
   - Every `Pane` holds a reference to `s.snapshotFiles` via `header.tree`, and `fillFolderMenu` scans all 300k paths with `hasPrefix` instead of binary-searching the already-sorted array or querying a shared directory index on `Session`.
5. **`SearchController` stores child items in an external `[ObjectIdentifier: [Item]]` dictionary instead of on `Group` (`Navigator.swift:508-527, 613-631`)**:
   - `Item` already holds `let group: Group`, while `Group` holds `matches: [GrepMatch]` instead of `items: [Item]`, forcing a dictionary hash lookup by `ObjectIdentifier(g)` on every `outlineView(_:numberOfChildrenOfItem:)` and `outlineView(_:child:ofItem:)` call.

### Unenforced Invariants
1. **`NSOutlineView.row(forItem:)` returns `-1` for collapsed/unexpanded items, which corrupts Swift's `Foundation.IndexSet` (`Inspector.swift:315-321`, `Navigator.swift:302-306`)**:
   - `Inspector.follow(lineIndex:)` assumes `rows.insert(outline.row(forItem: e))` followed by `rows.remove(-1)` yields a valid `IndexSet` of visible row indices. In Swift Foundation, `IndexSet.insert(-1)` followed by `IndexSet.remove(-1)` is a **no-op on `-1`**, leaving `-1` inside `rows` and causing `outline.selectRowIndexes(rows, byExtendingSelection: false)` to fail completely.
   - `ChangesController.selectFocus()` assumes `outline.parent(forItem: target)` works before `target`'s parent folders have been expanded in `NSOutlineView`. In AppKit, `NSOutlineView` only knows parent pointers for items whose parent has been expanded at least once since `reloadData()`.
2. **UTF-16 code unit offsets vs Unicode grapheme cluster / surrogate pair boundaries (`Navigator.swift:666-669`)**:
   - `SearchController` slices `NSString` at `let cut = r.location - 10` without `rangeOfComposedCharacterSequence(at:)`, splitting surrogate pairs in half, and never bounds the suffix length of `m.text` before passing it to `NSTextField`.
3. **Selection-change callbacks (`outlineViewSelectionDidChange` / `tableViewSelectionDidChange`) vs multi-selection and programmatic selection (`Navigator.swift:136, 483`, `NotesPane.swift:85, 103`)**:
   - `ChangesController.outline` enables `allowsMultipleSelection = true`, which causes `⌘`-click to extend selection (`selectedRowIndexes.count == 2`) instead of replacing it, while `outlineViewSelectionDidChange` guards `selectedRowIndexes.count == 1`—making `⌘`-click to open a file beside the current pane unreachable whenever a row is already selected.
   - `NotesPane.setNotes` calls `table.selectRowIndexes(...)` without a `suppress` guard, firing `tableViewSelectionDidChange` -> `notesPaneOpen` during programmatic reloads when `table` is first responder.

### How This Fits the Plan's Target Design
- **Step 1 (Confirmed bugs + correctness fixes)**: Fix the `Inspector.follow` `IndexSet(-1)` corruption bug and deleted-line enclosing-symbol failure, `ChangesController` `⌘`-click beside bug, `ChangesController.selectFocus()` collapsed-parent bug, `fileTree` merged-folder unreachable unchanged files bug, `SearchController` UTF-16 surrogate split and `begin(_:word:)` state bug, `compactDate` future-timestamp bug, `NotesPane` programmatic selection / focus-stealing pane explosion bug, `NoteEditor` text view `minSize` hit-test bug, and `JumpPanel` stale-items / post-dismiss search bug (alongside the already-known `rowViewForItem` reuse fix and `Inspector.merge` `beginUpdates`/`endUpdates` fix).
- **Step 2 (Admission limits & lifetimes)**: Cap `SearchController` match line snippets (~160 UTF-16 units past match end, aligned to composed character sequences) and `NoteCell` display strings before handing them to `NSTextField`.
- **Step 3 (Cheap UI fast paths)**: Keep persistent `ChangesController.Item` nodes updated in place via `outline.reloadItem` on review toggles, deduplicate `setFiles` / `setNotes` / `PaneHeader.updateSymbol` / `ChangeCounter.show`, update only the card entry in `Inspector.updateCard`, replace $O(R \cdot S)$ and $O(D^3 \cdot N)$ passes in `Inspector.rebuild()` with $O(R \log S)$ and 1-pass $O(N)$, binary-search `PaneHeader.tree` in `fillFolderMenu`, cache monochrome SF Symbol `NSImage`s and `RawChange.reviewKey`, and use `Set` for `selectedPaths` filtering.
- **Step 7 (Search)**: Share the off-main candidate arena and top-$k$ narrowing scorer with `ChangesController.filter` ("Find File") so typing in the Navigator filter never blocks the main thread or rebuilds a 300k-element `Set<String>`.

---

## 2. Ranked Findings

### Finding 1: `Inspector.follow(lineIndex:)` Inserts `-1` into `IndexSet` When a Section Is Folded, and `rows.remove(-1)` Fails to Remove It—Breaking Selection Across the Entire Inspector and Scrolling to Row `-1`
- **Location**: `Sources/SextantApp/Inspector.swift:295-327`
- **Category**: Bug
- **Plan Step**: Step 1
- **Evidence**:
  In `Inspector.follow(lineIndex:)`:
  ```swift
  for section in sections {
      if case .section("Outline") = section.kind, let e = innermost(section.children) { rows.insert(outline.row(forItem: e)) }
      if case .section("Changes") = section.kind, let e = section.children.first(where: {
          if case .change(let r, _, _) = $0.kind { r.run.lines.contains(lineIndex) } else { false }
      }) {
          rows.insert(outline.row(forItem: e))
      }
  }
  rows.remove(-1)
  suppress = true
  outline.selectRowIndexes(rows, byExtendingSelection: false)
  if let first = rows.first, outline.window?.firstResponder !== outline { outline.scrollRowToVisible(first) }
  ```
  When the user folds (collapses) `"Outline"`, `"Changes"`, or `"Files"` in the Inspector, `outline.row(forItem: e)` returns `-1`. `Inspector.follow` inserts `-1` into `var rows = IndexSet()`, intending to strip it afterwards with `rows.remove(-1)`.
  However, in Swift Foundation's `IndexSet`, inserting a negative integer `-1` corrupts the internal range table and **`rows.remove(-1)` is a no-op**:
  - When `"Changes"` is folded (`row = -1`) and `"Outline"` is expanded (`row = 3`), `rows.insert(-1); rows.insert(3); rows.remove(-1)` leaves `rows.contains(-1) == true` and `rows.count == 2`. When passed to `outline.selectRowIndexes(rows, byExtendingSelection: false)`, AppKit rejects the corrupted `IndexSet` and leaves the outline's previous selection untouched (`selected = [1, 3]` instead of `[3]`).
  - When `"Outline"` is folded and the caret moves to an unchanged line (`onlyMinus1`: `rows.insert(-1); rows.remove(-1)`), `rows.isEmpty` is **`false`**, `rows.first` is **`Optional(-1)`**, `outline.selectRowIndexes(rows, byExtendingSelection: false)` fails to deselect the previously selected row, and `outline.scrollRowToVisible(-1)` is called!
  - Verified by `SidebarsAuditBench` Test 1a (`./.build/release/SidebarsAuditBench`):
    ```
    [1a: IndexSet(-1) when section folded] after insert(-1), insert(3), remove(-1) -> contains(-1)=true count=2 (expected 1!), first=Optional(3) (expected Optional(3)!)
    [1a-cont: outline.selectRowIndexes(rows) with corrupted IndexSet(-1, 3)] selected=[1, 3] | rows.first=Optional(3)
    [1a-only: onlyMinus1 after insert(-1)+remove(-1)] isEmpty=false first=Optional(-1) Array=[-1] selectedAfterSelectRowIndexes=[2] (stale row 2 stays selected or corrupts!)
    ```
- **Fix**: Never insert negative row indices into `IndexSet`. Guard `let r = outline.row(forItem: e), r >= 0` before calling `rows.insert(r)` in all three branches of `follow(lineIndex:)`, and remove `rows.remove(-1)`.

---

### Finding 2: `ChangesController` "Find File" Filter Runs `Set(paths)` + `rankFuzzy` Synchronously on `@MainActor` on Every Keystroke and Every Review Toggle (1,085.7 ms Stall at 300k Files)
- **Location**: `Sources/SextantApp/Navigator.swift:153, 287, 320-337` (calling `rankFuzzy` at `Sources/SextantCore/Jump.swift:40-44`)
- **Category**: Slowness / Waste
- **Plan Step**: Step 3 & Step 7
- **Evidence**:
  `ChangesController.filter` sets `filter.sendsSearchStringImmediately = true` (`Navigator.swift:153`), and `controlTextDidChange` (`Navigator.swift:489`) calls `rebuild()` synchronously on the main thread:
  ```swift
  private func rebuild() {
      let byPath = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
      if !query.isEmpty {
          let all = Array(Set(paths).union(byPath.keys))
          items = rankFuzzy(query, all).prefix(500).map { Item(kind: .file, name: $0, path: $0, file: byPath[$0], showsFolder: true) }
      } else { ... }
  ```
  1. On **every keystroke**, `Array(Set(paths).union(byPath.keys))` hashes all 100k–300k `paths` into a brand-new `Set<String>` and converts it back to an `Array`, even though `paths` (`s.snapshotFiles`) is already sorted and deduplicated and only deleted files in `byPath.keys` could be missing.
  2. `rankFuzzy(query, all)` runs synchronously on `@MainActor`, bridging `(p as NSString).lastPathComponent` and lowercasing `query`, `name`, and `candidate` for every file, sorting **all** matches, and only then taking `.prefix(500)`.
  3. While a filter query is active (`!query.isEmpty`), **every `refreshReviewState()`** (`Navigator.swift:287`, triggered whenever the user presses Space to mark a filtered file reviewed) calls `rebuild()`, re-running the entire 300k-path `Set` construction and `rankFuzzy` sort on the main thread just to update one row's checkmark!
  - Measured by `SidebarsAuditBench` Test 3a (`./.build/release/SidebarsAuditBench`):
    ```
    [3a: ChangesController.rebuild filter N=  1000] total=3.2 ms (Set+union=0.1 ms, rankFuzzy=3.1 ms)
    [3a: ChangesController.rebuild filter N= 10000] total=31.9 ms (Set+union=0.5 ms, rankFuzzy=31.1 ms)
    [3a: ChangesController.rebuild filter N=100000] total=337.6 ms (Set+union=6.1 ms, rankFuzzy=331.3 ms)
    [3a: ChangesController.rebuild filter N=300000] total=1085.7 ms (Set+union=30.9 ms, rankFuzzy=1052.5 ms)
    ```
- **Fix**:
  1. Precompute the merged path list once in `setFiles(_:paths:)` (appending only `files.filter { $0.diff.change.isDeleted }.map(\.path)` to `paths`), never on keystroke.
  2. In `refreshReviewState()`, update `Item` review counts and call `outline.reloadItem` on affected rows without re-running the filter or rebuilding the tree.
  3. Run file-filter ranking asynchronously off the main thread with cancellation, narrowing over prior matches as the query grows, and a bounded top-500 min-heap (sharing Step 7's candidate arena).

---

### Finding 3: `SearchController` Never Caps Long Match Lines Before Setting `NSTextField.attributedStringValue` (239.8 ms/row on a 520 KB Minified Line) and Splits UTF-16 Surrogate Pairs in Half (`U+FFFD` Corruption)
- **Location**: `Sources/SextantApp/Navigator.swift:660-677`
- **Category**: Bug / Slowness
- **Plan Step**: Step 1 & Step 2
- **Evidence**:
  In `SearchController.outlineView(_:viewFor:item:)`:
  ```swift
  var text = m.text.trimmingCharacters(in: .whitespaces) as NSString
  var r = text.range(of: query, options: caseSensitive ? [] : .caseInsensitive)
  if r.location != NSNotFound, r.location > 16 {
      let cut = r.location - 10
      text = ("…" + text.substring(from: cut)) as NSString
      r.location -= cut - 1
  }
  let start = s.length
  s.append(NSAttributedString(string: text as String, attributes: [.font: mono, .foregroundColor: NSColor.themed("fg")]))
  if r.location != NSNotFound {
      s.addAttribute(.backgroundColor, value: NSColor.themed("findMatch"), range: NSRange(location: start + r.location, length: r.length))
  }
  cell.textField?.attributedStringValue = truncatingTail(s)
  ```
  1. **Uncapped suffix on long lines**: While `cut` trims characters *before* `r.location - 10`, nothing caps `text` *after* the match. When `git grep` matches inside a minified JS/CSS/JSON line (e.g. 520 KB), `text.substring(from: cut)` copies the entire 520 KB suffix into `NSAttributedString` and assigns it to `cell.textField?.attributedStringValue`, forcing TextKit inside `NSTextFieldCell` to typeset hundreds of kilobytes on `@MainActor` for a single 24pt sidebar row that only displays ~40 characters. Twenty visible matches in a minified file stall the main thread for **~4.8 seconds**.
  2. **UTF-16 surrogate pair split**: `let cut = r.location - 10` subtracts 10 UTF-16 code units without calling `text.rangeOfComposedCharacterSequence(at: cut)`. When a 2-unit non-BMP character (such as `🎉` or `𝕏`) straddles `r.location - 10` (high surrogate at `r.location - 11`, low surrogate at `r.location - 10`), `text.substring(from: cut)` starts on an unpaired low surrogate, which bridges to `U+FFFD` (``) in `"…" + text.substring(from: cut)`.
  - Verified and measured by `SidebarsAuditBench` Tests 5a & 5b (`./.build/release/SidebarsAuditBench`):
    ```
    [5a: SearchController UTF-16 surrogate slice] r.location=19 rawCut=9 | broken='…123456789target_symbol()' (contains U+FFFD=true) | fixed='…🎉123456789target_symbol()' (contains U+FFFD=false)
    [5b: SearchController cell with 520 KB line] current(uncapped suffix)=239.83 ms/row | fixed(160-char snippet cap)=0.0542 ms/row (4424x)
    ```
- **Fix**: Align both the prefix cut and a suffix cap (e.g. `min(text.length, NSMaxRange(r) + 160)`) using `text.rangeOfComposedCharacterSequence(at:)` before slicing `text` and before trimming/constructing `NSAttributedString` (4,424x speedup on long lines, zero `U+FFFD` corruption).

---

### Finding 4: `Inspector.rebuild()` Runs an $O(R \cdot S)$ `flatten` + Linear Enclosing Scan (422 ms at 5k Runs/Symbols) and Re-runs in Full on Every Caret Move When Blame Is Active
- **Location**: `Sources/SextantApp/Inspector.swift:176-204, 289, 387` and `Sources/SextantApp/RepoWindowController.swift:719-723`
- **Category**: Slowness / Waste
- **Plan Step**: Step 3
- **Evidence**:
  1. In `Inspector.rebuild()` (`Inspector.swift:186-190`):
     ```swift
     if f.isChange, !f.keyedRuns.isEmpty {
         let flat = flatten(items)
         out.append(Entry(.section("Changes"), children: f.keyedRuns.map { r in
             Entry(.change(r, enclosing: flat.last { $0.change != .deleted && $0.span.contains(r.run.newLine) }?.name, read: isRead(f, r)))
         }))
     }
     ```
     where `flatten(_ items: [OutlineItem]) -> [OutlineItem] { items.flatMap { [$0] + flatten($0.children) } }` (`Inspector.swift:289`) allocates and copies arrays at every tree level, and for each run `r` in `f.keyedRuns` linearly scans `flat` from the end ($O(R \cdot S)$).
  2. When Blame is enabled (`blameOn == true`), `RepoWindowController.readerCaretMoved` (`RepoWindowController.swift:719-723`) runs on **every caret movement**:
     ```swift
     func readerCaretMoved(_ r: Reader) {
         guard r === reader else { return }
         if case .file? = focus { inspector.follow(lineIndex: reader.caret?.line) }
         if blameOn { inspector.updateCard(card()) }
     }
     ```
     `inspector.updateCard(card())` (`Inspector.swift:176-179`) calls `rebuild()`, which:
     - Rebuilds the entire `"Changes"` section ($O(R \cdot S)$) and `"Outline"` section from scratch,
     - Runs `merge(fresh, into: root)` and `expandSections()`,
     - Reconfigures every visible row in `outline` via `enumerateAvailableRowViews`,
     - Scans `0..<outline.numberOfRows` for `.card` (`Inspector.swift:217`),
     - Calls `follow(lineIndex: caret)` a **second** time,
     - And because `InspectorCardCell` (`Inspector.swift:387`) has no cell reuse identifier (`case .card: InspectorCardCell()`), any card row recreation allocates a fresh `InspectorCardCell`.
  - Measured by `SidebarsAuditBench` Test 2b (`./.build/release/SidebarsAuditBench`):
    ```
    [2b: Inspector enclosing lookup ( 500 symbols,  500 runs)] current(flatten+linear)=4.80 ms | fixed(tree bsearch)=0.02 ms (303.9x)
    [2b: Inspector enclosing lookup (2000 symbols, 2000 runs)] current(flatten+linear)=66.86 ms | fixed(tree bsearch)=0.07 ms (933.8x)
    [2b: Inspector enclosing lookup (5000 symbols, 5000 runs)] current(flatten+linear)=422.12 ms | fixed(tree bsearch)=0.20 ms (2151.6x)
    ```
- **Fix**:
  1. Replace `flatten(items)` + `flat.last { ... }` with a direct binary search down the sorted `items` hierarchy ($O(\log S)$ per run: **0.20 ms vs 422.12 ms**, **2,151x faster**).
  2. Make `updateCard(_:)` update only the card section/entry in place (and skip when the blamed commit or line hasn't changed), rather than calling `rebuild()`.
  3. Give `InspectorCardCell` a static reuse `identifier` and reuse it via `outline.makeView(withIdentifier:owner:)`.

---

### Finding 5: `Inspector.follow(lineIndex:)` Fails to Highlight the Enclosing Definition Whenever the Caret Lands on a Deleted Line (Including Every Modification Hunk's Landing Line)
- **Location**: `Sources/SextantApp/Inspector.swift:304-312` and `Sources/SextantCore/Outline.swift:81-84`
- **Category**: Bug
- **Plan Step**: Step 1
- **Evidence**:
  In `Inspector.follow(lineIndex:)`:
  ```swift
  let line = f.lines[lineIndex]
  let newLine = line.kind == .deleted ? nil : line.newNo - 1
  func innermost(_ entries: [Entry]) -> Entry? {
      for e in entries {
          guard case .symbol(let s) = e.kind else { continue }
          let hit = s.change == .deleted ? (line.kind == .deleted && line.oldNo - 1 == s.line) : newLine.map { s.span.contains($0) } ?? false
          if hit { return innermost(e.children) ?? e }
      }
      return nil
  }
  ```
  1. **Deleted line inside a `.modified` definition**: In unified diffs, every modification hunk lists `.deleted` (`-`) lines before `.added` (`+`) lines. When opening a file (`open(path, at: .firstChange)`) or stepping changes (`nextChange` / `previousChange`), `changeStops` lands the caret on the first `.deleted` line of the hunk. At that line, `line.kind == .deleted`, so `newLine` is set to `nil`. For every `.modified` symbol in the Outline, `s.change == .deleted` is `false` and `newLine.map { s.span.contains($0) } ?? false` evaluates to `false`—so the Inspector Outline highlights **nothing**!
  2. **Body lines of a `.deleted` definition**: When an entire function is deleted (`s.change == .deleted`), `Outline.swift:83` overwrites `s.span` with `at...at` (the single new-side line where the deletion sits) and keeps only `s.line = s.nameLine` (the 0-based old-side signature line). `follow(lineIndex:)` checks `line.oldNo - 1 == s.line`, which only matches the signature line and fails on every other deleted line of the function body.
  3. **Pure deletion at the end of a definition in `"Changes"` (`Inspector.swift:189`, `FileTree.swift:127`)**: For a pure deletion (`r.additions == 0`), `changeRuns` sets `r.newLine = lines[start - 1].newNo` (which is `1 +` the 0-based new-side line before the deletion). If lines were deleted at the end of a function or file, `r.newLine` is one past `s.span.upperBound`, so `s.span.contains(r.newLine)` is `false` and the change row omits its enclosing function name.
  - Verified by `SidebarsAuditBench` Test 1c (`./.build/release/SidebarsAuditBench`):
    ```
    [1c: Inspector.follow on deleted line of modified function] symbol.change=modified span=0...2 | currentHit=false (FAILS to highlight!) | fixedHit=true
    ```
- **Fix**:
  1. Preserve `oldSpan: ClosedRange<Int>?` on deleted `OutlineItem`s (or check `oldSpan` when `s.change == .deleted`).
  2. When `line.kind == .deleted` and no `.deleted` symbol contains `line.oldNo - 1`, resolve `newLine` to the nearest enclosing new-side line (`f.run(at: lineIndex)?.run.newLine` clamped to the preceding context line when `additions == 0`) so `.modified` enclosing symbols remain highlighted on deleted lines.

---

### Finding 6: Command-Clicking a File in `ChangesController.outline` Fails to Open It Beside the Current Pane Whenever Any Row Is Already Selected
- **Location**: `Sources/SextantApp/Navigator.swift:136, 423-426, 482-485` and `Sources/SextantApp/RepoWindowController.swift:631-639`
- **Category**: Bug
- **Plan Step**: Step 1
- **Evidence**:
  `RepoWindowController.navigatorOpen(path:line:)` (`RepoWindowController.swift:631-639`) is documented and implemented to open a Command-clicked file in a new pane beside the focused pane:
  ```swift
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
  ```
  However:
  1. Whenever a pane shows a file or the overview, `ChangesController.showFocus` selects that row in `outline` (`outline.selectedRowIndexes` has count `1`).
  2. `ChangesController.loadView()` sets `outline.allowsMultipleSelection = true` (`Navigator.swift:136`).
  3. When the user holds `⌘` (Command) and clicks another file `B` in `outline`, AppKit's `NSOutlineView` treats `⌘`-click as multi-selection toggle and **adds** `B` to `outline.selectedRowIndexes` (making `outline.selectedRowIndexes.count == 2`), or if clicking the already-selected file `A`, removes `A` (making `count == 0`).
  4. `ChangesController.outlineViewSelectionDidChange` (`Navigator.swift:482-485`) guards `outline.selectedRowIndexes.count == 1`:
     ```swift
     func outlineViewSelectionDidChange(_ notification: Notification) {
         guard !suppress, outline.selectedRowIndexes.count == 1, let i = outline.item(atRow: outline.selectedRow) as? Item else { return }
         activate(i)
     }
     ```
     Because `count` is `2` (or `0`), `outlineViewSelectionDidChange` returns early without calling `activate(i)`! And `outlineClicked()` (`Navigator.swift:423`) only handles `i.kind == .folded`. Thus `navigatorOpen` is never called on `⌘`-click!
- **Fix**: Handle `⌘`-click (or check `outline.clickedRow` when `.command` is held, or use `⌥`-click / handle single-item activation in `outlineClicked` when `clickedRow >= 0`) so clicking a file with the open-beside modifier opens it in a side pane rather than silently multi-selecting without activating.

---

### Finding 7: `ChangesController.selectFocus()` Fails to Select or Reveal Focused Files Inside Collapsed or Unrevealed Folders
- **Location**: `Sources/SextantApp/Navigator.swift:296-316`
- **Category**: Bug
- **Plan Step**: Step 1
- **Evidence**:
  In `ChangesController.selectFocus()`:
  ```swift
  private func selectFocus() {
      let target: Item? = switch focus {
      case .overview: items.first { $0.kind == .allChanges }
      case .file(let p): find(p, in: items)
      case .none: nil
      }
      suppress = true
      defer { suppress = false }
      guard let target else { outline.deselectAll(nil); return }
      var parent = outline.parent(forItem: target)
      var chain: [Any] = []
      while let p = parent { chain.append(p); parent = outline.parent(forItem: p) }
      for p in chain.reversed() { outline.expandItem(p) }
      let r = outline.row(forItem: target)
      guard r >= 0 else { return }
      if outline.selectedRowIndexes != [r] { outline.selectRowIndexes([r], byExtendingSelection: false) }
      outline.scrollRowToVisible(r)
  }
  ```
  Two distinct bugs break `selectFocus()`:
  1. **Collapsed parent folders (`showsUnchanged == true` or user-collapsed folders)**: In AppKit, `NSOutlineView.parent(forItem:)` only knows the parent of items that `NSOutlineView` has already queried from its `dataSource`. When a parent folder `P` has not yet been expanded since `outline.reloadData()` (which is true for every unchanged folder in `showsUnchanged == true` mode because `expandEach` at `Navigator.swift:363` only expands folders where `shouldOpen(i)` is `true`), `outline.parent(forItem: target)` returns **`nil`**! `chain` is empty, `P` is never expanded, `outline.row(forItem: target)` returns `-1`, and `selectFocus()` silently aborts without selecting or scrolling to `target`.
  2. **Unchanged files opened when `showsUnchanged == false`**: When the user opens an unchanged file via Jump to Definition, Go to Anything, Find in Files, or the header jump bar while `showsUnchanged == false`, its folder is not in `revealed`, so `target = find(p, in: items)` returns `nil` and `outline.deselectAll(nil)` clears the navigator selection altogether.
  - Verified by `SidebarsAuditBench` Test 4a (`./.build/release/SidebarsAuditBench`):
    ```
    [4a: selectFocus() when parent folder is collapsed] outline.parent(forItem: leaf)=non-nil | rowCurrent=-1 (FAILS!) | rowFixed=2
    ```
- **Fix**: Have `find(_:in:)` return the ancestor chain `[Item]` from `items` down to `target` (instead of querying `outline.parent(forItem:)`), expand each ancestor folder in top-down order (`for folder in chain.dropLast() { outline.expandItem(folder) }`), and then query `outline.row(forItem: target)`.

---

### Finding 8: `fileTree` Drops Unchanged Files in Merged Parent Folders Without an `.unchanged` Row and Ignores `revealed`
- **Location**: `Sources/SextantCore/FileTree.swift:92-109` (called by `ChangesController.rebuild()` at `Sources/SextantApp/Navigator.swift:328`)
- **Category**: Bug
- **Plan Step**: Step 1
- **Evidence**:
  In `Folder.node` and `Folder.mergedChild` (`FileTree.swift:92-109`):
  ```swift
  func node(name: String, path: String, showAll: Bool, revealed: Set<String>, changed: Set<String>, reviewed: Set<String>) -> FileNode {
      if let (childName, child) = mergedChild(path: path, showAll: showAll, changed: changed) {
          var n = child.node(name: childName, path: path + "/" + childName, showAll: showAll, revealed: revealed, changed: changed, reviewed: reviewed)
          n.name = name + "/" + n.name
          return n
      }
      ...
  }

  private func mergedChild(path: String, showAll: Bool, changed: Set<String>) -> (String, Folder)? {
      if showAll || self.changed == 0 {
          guard files.isEmpty, folders.count == 1, let only = folders.first else { return nil }
          return (only.key, only.value)
      }
      guard !files.contains(where: { changed.contains(path + "/" + $0) }) else { return nil }
      let leading = folders.filter { $0.value.changed > 0 }
      guard leading.count == 1, let only = leading.first else { return nil }
      return (only.key, only.value)
  }
  ```
  When `showAll == false` and folder `"a"` has unchanged files/subfolders (`"a/unchanged1.swift"`, `"a/un_dir/..."`) plus a single changed subfolder `"a/b"` (`"a/b/changed.swift"`):
  1. `mergedChild` merges `"a"` and `"b"` into a single folder node `name = "a/b"`, `path = "a/b"` whose children are only `b.nodes(...)`.
  2. All unchanged files and unchanged subfolders inside `"a"` are silently discarded—no `.unchanged(count)` row is emitted for `"a"`, and even if `"a"` or `"a/b"` is in `revealed`, `mergedChild` does not check `revealed`, so `"a"`'s unchanged files can never be revealed in Changed Files mode.
  3. Additionally, if a file `"foo"` was replaced by a directory `"foo/bar"` (or vice versa) between the base and target revisions, `Folder.insert` (`FileTree.swift:44-53`) inserts `"foo"` into both `files` and `folders`, emitting two sibling items with identical `path == "foo"`.
  - Verified by `SidebarsAuditBench` Test 4b (`./.build/release/SidebarsAuditBench`):
    ```
    [4b: fileTree merged folder] rootNode.name='a/b' path='a/b' children=["file:a/b/changed.swift", "file:a/b/unchanged4.swift"] -> 'a/unchanged1.swift', 'a/unchanged2.swift', 'a/un_dir' are COMPLETELY UNREACHABLE even with revealed=['a', 'a/b']!
    ```
- **Fix**: Only merge a folder with its single child folder when the parent folder has no other files or subfolders (`files.isEmpty && folders.count == 1`), or do not merge when `!revealed.isDisjoint(with: ...)` and include the parent's hidden count in an `.unchanged` item so unchanged files in intermediate directories can be unfolded.

---

### Finding 9: `ChangesController.selectedPaths` + `toggleReviewed` / `validateMenuItem` / `navigatorFileMenu` Perform $O(C \cdot P)$ Linear `Array.contains` Scans on the Main Thread (134.1 ms at 10k Changed Files)
- **Location**: `Sources/SextantApp/Navigator.swift:399-413`, `Sources/SextantApp/RepoWindowController.swift:593-595`, and `Sources/SextantApp/WindowActions.swift:127, 318-322`
- **Category**: Slowness / Waste
- **Plan Step**: Step 3
- **Evidence**:
  1. In `ChangesController.changedPaths(_ rows: IndexSet)` (`Navigator.swift:399-413`):
     ```swift
     case .folder: out += files.map(\.path).filter { $0.hasPrefix(i.path + "/") }
     ```
     For each selected folder row, it allocates `files.map(\.path)` and scans all `files` ($O(\text{selected folders} \cdot C)$).
  2. In `RepoWindowController.toggleReviewed` (`RepoWindowController.swift:594`), `navigatorFileMenu` (`WindowActions.swift:127`), and `validateMenuItem` (`WindowActions.swift:320`):
     ```swift
     let paths = actionPaths
     let files = changes.filter { paths.contains($0.path) }
     ```
     `paths` is `[String]`. When `"All Changes"` or a top-level folder is selected in the navigator (`P = C`), `changes.filter { paths.contains($0.path) }` performs $O(C^2)$ string comparisons on the main thread—including inside `validateMenuItem` whenever AppKit validates the menu bar or key equivalents!
  - Measured by `SidebarsAuditBench` Test 4c (`./.build/release/SidebarsAuditBench`):
    ```
    [4c: toggleReviewed/validateMenuItem filter C= 1000] current(Array.contains)=1.32 ms | fixed(Set.contains)=0.082 ms (16x)
    [4c: toggleReviewed/validateMenuItem filter C=10000] current(Array.contains)=134.11 ms | fixed(Set.contains)=0.844 ms (159x)
    ```
- **Fix**: Convert `paths` to `let pathSet = Set(paths)` before filtering `changes` in `toggleReviewed`, `navigatorFileMenu`, and `validateMenuItem` (**159x faster** at 10k files), and collect changed file paths directly from the `Item` subtree in `changedPaths(_:)` instead of scanning `files.map(\.path)` per folder.

---

### Finding 10: `PaneHeader.crumbClicked` Runs `fillFolderMenu` Twice per Click, Linearly Scanning All 300k Paths in `tree` Both Times (9.13 ms vs 0.012 ms, 737x), and Omits Deleted Files
- **Location**: `Sources/SextantApp/PaneHeader.swift:290-343`
- **Category**: Slowness / Bug
- **Plan Step**: Step 3 & Step 1
- **Evidence**:
  In `PaneHeader.crumbClicked(_:)` (`PaneHeader.swift:290-298`):
  ```swift
  let menu = NSMenu(title: dir)
  menu.delegate = self
  menuNeedsUpdate(menu)
  let selected = menu.items.first { $0.state == .on }
  menu.popUp(positioning: selected, at: NSPoint(x: 0, y: sender.bounds.maxY + 2), in: sender)
  ```
  1. **Double execution**: `crumbClicked` sets `menu.delegate = self`, calls `menuNeedsUpdate(menu)` (which runs `fillFolderMenu(menu)`), and then calls `menu.popUp(...)`, which causes AppKit to invoke `menu.delegate?.menuNeedsUpdate(menu)` a **second time** before showing the menu, destroying and recreating every `NSMenuItem` and submenu.
  2. **Linear scan over sorted `tree`**: `fillFolderMenu` loops `for p in tree where p.hasPrefix(prefix)` across the entire `tree` array (up to 300,000 paths in `snapshotFiles`), even though `tree` is already sorted! Because `tree` is sorted, the range of paths starting with `prefix` is contiguous, and each subdirectory `prefix + name + "/"` is also a contiguous block that can be jumped over via binary search in $O(K \log N)$ where $K$ is the number of immediate entries in `dir`.
  3. **Deleted files missing from `tree`**: `tree` is populated from `git.files(in: snapshot)` (`RepoWindowController.swift:278, 283`), which only lists files existing in the new snapshot. When reading a deleted file (or a folder containing deleted files), those paths are absent from `tree`, so clicking the file/folder in `PaneHeader` fails to check or list the deleted file (and shows `"Empty"` if the directory itself was deleted).
  - Measured by `SidebarsAuditBench` Test 6a (`./.build/release/SidebarsAuditBench`):
    ```
    [6a: PaneHeader.fillFolderMenu N= 10000] current(2x linear scan)=0.39 ms | fixed(1x binary search + jump)=0.0078 ms (50x)
    [6a: PaneHeader.fillFolderMenu N=100000] current(2x linear scan)=3.06 ms | fixed(1x binary search + jump)=0.0090 ms (341x)
    [6a: PaneHeader.fillFolderMenu N=300000] current(2x linear scan)=9.13 ms | fixed(1x binary search + jump)=0.0124 ms (737x)
    ```
- **Fix**:
  1. In `crumbClicked`, populate `menu` once via `fillFolderMenu(menu)` and only assign `menu.delegate = self` on the lazy child `sub` menus (not on the root `menu` already populated).
  2. In `fillFolderMenu`, binary-search `tree` (sorted with standard UTF-8 `<`) for `prefix` and jump over each seen subdirectory `prefix + name + "/\u{10FFFF}"` via binary search (**737x faster** at 300k paths).
  3. Include deleted paths from `s.changes` when building `s.snapshotFiles`.

---

### Finding 11: `CommitCell.configure` Formats Two ICU Dates and Recomputes Every File's `reviewKey` String on Every `reviewsChanged` Notification, and `compactDate` Formats Future Timestamps as `"now"`
- **Location**: `Sources/SextantApp/Cells.swift:194-206, 329-346`, `Sources/SextantApp/Navigator.swift:275-278, 448-452`, and `Sources/SextantApp/ReviewStore.swift:49-51`
- **Category**: Bug / Waste
- **Plan Step**: Step 1 & Step 3
- **Evidence**:
  1. **Future timestamp bug in `compactDate(_:)` (`Cells.swift:194-196`)**:
     ```swift
     func compactDate(_ d: Date) -> String {
         let s = -d.timeIntervalSinceNow
         if s < 60 { return "now" }
     ```
     When a commit's timestamp is in the future (`d > Date()`, e.g. from clock skew, container/VM drift, or timezone offset during rebase), `s = -d.timeIntervalSinceNow` is **negative**, which satisfies `s < 60` and displays `"now"` for commits hours, days, or years in the future!
  2. **Per-cell ICU formatting + $O(\text{commits} \cdot \text{files})$ `reviewKey` string allocations on every hunk read**:
     Every time a hunk is marked read or a file is marked reviewed, `reviewsChanged` calls `navigator.changes.refreshCommitProgress()` (`Navigator.swift:275-278`), which reloads every commit row in `commits`. For each visible commit row, `CommitCell.configure` (`Cells.swift:329-346`):
     - Calls `compactDate(d)` (which creates `Date.FormatStyle` and queries `Calendar.current` twice for commits > 7 days old),
     - Eagerly calls `d.formatted(date: .abbreviated, time: .shortened)` just to build `toolTip`,
     - And calls `reviews?.progress(c.changes)` (`ReviewStore.swift:49-51`), which evaluates `$1.reviewKey` (`"\(oldOid)->\(newOid):\(status):\(path)"` — allocating a new heap `String` per file in the commit) on every call!
  - Verified and measured by `SidebarsAuditBench` Tests 7a & 7b (`./.build/release/SidebarsAuditBench`):
    ```
    [7a: compactDate with future commit timestamp (+3 days)] s=-259200s -> returns 'now' (BUG: future dates <60 check matches all negative s!)
    [7b: CommitCell.configure x200 commits (each 200 files)] current=12.87 ms | fixed(no eager tooltip format + cached reviewKey)=3.92 ms (3.3x)
    ```
- **Fix**:
  1. In `compactDate(_:)`, guard `s >= 0` for relative `"now"`/`"m"`/`"h"`/`"d"` buckets and fall through to the calendar date format when `s < 0`.
  2. Store `reviewKey` on `RawChange` (or cache commit progress) and only update `CommitCell.pie` / `subject.textColor` in `refreshCommitProgress()` instead of reformatting `meta`, `date`, and `toolTip` on every review state change.

---

### Finding 12: `PaneHeader` and `ChangeCounter` Perform Unconditional String Formatting, Linear Symbol/Change Scans, and Control Mutations on Every Scroll Notification
- **Location**: `Sources/SextantApp/PaneHeader.swift:158-193, 257-274`, `Sources/SextantApp/ChangeCounter.swift:45-50`, and `Sources/SextantApp/Reader.swift:815-831, 928-936`
- **Category**: Waste / Bug
- **Plan Step**: Step 3 & Step 1
- **Evidence**:
  On every scroll notification (`Reader.scrolled` -> `updateHeader()`, up to 185 times during a single reload) and every caret move (`codeViewCaretMoved` -> `updateHeader()`):
  1. `PaneHeader.update` constructs a multi-part interpolated string `key` (`PaneHeader.swift:160`) that includes `\(style.theme.color("success"))|\(style.theme.color("danger"))` (formatting two `NSColor.description` strings on every scroll pixel).
  2. `PaneHeader.updateSymbol(line:)` (`PaneHeader.swift:262-274`) has **no deduplication guard**: even when `line` or `enclosing` is unchanged, it linearly scans `definitions.last { $0.lines.contains(line) }`, mutates `symbols.menu?.item(at: 0)?.title` and `.image`, calls `symbols.synchronizeTitleAndSelectedItem()`, and calls `symbols.setTitle(enclosing.name)`.
  3. `Reader.updateChangeCounter()` (`Reader.swift:815-831`) binary-searches `changeStops` in `changeOrdinal(atRow:starts:)`, then **linearly scans** `changeStops` twice in `changeStop(-1, from:)` (`changeStops.last { $0 < from }`) and `changeStop(1, from:)` (`changeStops.first { $0 > from }`), and calls `ChangeCounter.show(...)` (`ChangeCounter.swift:45-50`) which has **no deduplication guard** and unconditionally formats a new `String`, sets `label.stringValue` (invalidating `NSStackView` layout inside `NSGlassEffectView`), sets `accessibilityLabel`, and assigns `previous.isEnabled` and `next.isEnabled`.
  4. **Stale overview stats bug (`PaneHeader.swift:160`)**: In overview mode (`p == nil`), `shownKey` only hashes `files.count`, `files.first`, and `files.last`. If any middle file (`files[1..<files.count-1]`) changes its diff additions/deletions on refresh while the first and last files do not change, `key == shownKey` returns early and `PaneHeader.stats` displays stale `+additions −deletions`.
  5. **Redundant overview reload (`PaneHeader.swift:169, 284`)**: Clicking `"All Changes"` in `PaneHeader` when already in overview mode invokes `onShowOverview?()` -> `RepoWindowController.showOverview(in: p)`, which has no guard (unlike `navigatorShowOverview()` at `RepoWindowController.swift:649`) and reloads the entire overview from scratch.
  - Measured by `SidebarsAuditBench` Test 6b (`./.build/release/SidebarsAuditBench`):
    ```
    [6b: 185 scroll ticks in PaneHeader+ChangeCounter (500 defs, 200 hunks)] current=2.95 ms | fixed(dedup + bsearch)=0.009 ms (321x)
    ```
- **Fix**:
  1. Deduplicate `updateSymbol(line:)` by `lastSymbolLine` / `lastEnclosingName` and binary-search `definitions`.
  2. Deduplicate `ChangeCounter.show` by `(ordinal, count, canGoBack, canGoForward)` and derive `canGoBack`/`canGoForward` directly from the binary search index in `changeOrdinal` (`ordinal > 1 || (ordinal == 1 && from > changeStops[0])` and `ordinal < changeStops.count`) without scanning `changeStops`.
  3. Include total `(additions, deletions)` in `PaneHeader`'s state check (computed once per `Session` load rather than per `currentFile` change in overview), and guard `if case .overview? = p.focus { return }` in `header.onShowOverview`.

---

### Finding 13: `NotesPane` Fires `notesPaneOpen` on Programmatic Reloads, Steals Keyboard Focus and Spawns Unbounded Panes When Navigating Notes, and Reloads on Every Pane Switch
- **Location**: `Sources/SextantApp/NotesPane.swift:48, 82-106` and `Sources/SextantApp/RepoWindowController.swift:588-591, 735-740`
- **Category**: Bug / Waste
- **Plan Step**: Step 1 & Step 3
- **Evidence**:
  1. **Focus theft and unbounded pane creation on `j`/`k` or clicking notes (`RepoWindowController.swift:735-740`)**:
     ```swift
     func notesPaneOpen(_ note: Note) {
         guard let on = note.lines else { return }
         let anchor = Anchor.line(SideLine(number: on.range.upperBound, old: on.old))
         if focus != .file(on.path) { branch() }
         open(on.path, at: anchor)
     }
     ```
     Unlike `navigatorOpenResult` (`RepoWindowController.swift:642-647`, which passes `branch(takeKeyboard: false)` and sets `showsResults = true` to reuse a single side pane), `notesPaneOpen` calls `branch()` with the default `takeKeyboard: true` and never reuses the branched pane:
     - Pressing `j` in `NotesPane.table` to move to a note in another file immediately calls `branch(takeKeyboard: true)` -> `reader.focus()`, stealing keyboard focus out of `NotesPane.table` into the new pane's `CodeView` so the next `j` keypress scrolls code instead of stepping notes!
     - Clicking through 5 notes on 5 files (or clicking notes while in Overview mode where `focus != .file(on.path)` is always true) opens 5 separate panes!
  2. **Programmatic selection in `setNotes(_:)` triggers `tableViewSelectionDidChange` (`NotesPane.swift:82-86, 103-106`)**:
     ```swift
     func setNotes(_ n: [Note]) {
         let selected = Set(selection.map(\.id))
         notes = n
         table.reloadData()
         table.selectRowIndexes(IndexSet(notes.indices.filter { selected.contains(notes[$0].id) }), byExtendingSelection: false)
     ```
     `setNotes` has no `suppress` flag around `table.selectRowIndexes(...)`. Whenever `setNotes` runs while `table.window?.firstResponder === table`, `tableViewSelectionDidChange` fires `delegate?.notesPaneOpen(n)`.
  3. **Unconditional `table.reloadData()` on every pane switch (`NotesPane.swift:82`, `RepoWindowController.swift:531, 588-591`)**:
     `setNotes(_ n: [Note])` has no `guard n != notes else { return }`. Every time the user switches panes or opens/closes a pane on the same review, `paneFocusChanged()` -> `showNotes()` -> `setNotes(reviewNotes)` calls `table.reloadData()` on a table with `usesAutomaticRowHeights = true`, forcing Auto Layout measurement of every `NoteCell`.
- **Fix**:
  1. Guard `guard n != notes else { return }` in `NotesPane.setNotes(_:)`, and wrap `table.reloadData()` + `table.selectRowIndexes(...)` in `suppress = true; defer { suppress = false }`.
  2. In `notesPaneOpen(_:)`, reuse a branched pane with `branch(takeKeyboard: false)` (just like `navigatorOpenResult`) so stepping through notes with `j`/`k` keeps keyboard focus in `NotesPane` and reuses one side pane.

---

### Finding 14: `Inspector` Has Cubic-in-Depth $O(D^3 \cdot N)$ Recursion in `pruned` + `entry` When `changedOnly == true`, Scans All Rows for `.card` ($O(\text{rows})$), and Forcibly Re-expands User-Collapsed Symbols
- **Location**: `Sources/SextantApp/Inspector.swift:37, 193-194, 217, 225-287, 367-372`
- **Category**: Slowness / Bug
- **Plan Step**: Step 3 & Step 1
- **Evidence**:
  1. **Cubic-in-depth `pruned` + `entry` recursion (`Inspector.swift:193-194, 281-287`)**:
     ```swift
     // In rebuild():
     let shown = changedOnly ? pruned(items) : items
     let entries = shown.map(entry)
     ...
     private func entry(_ i: OutlineItem) -> Entry {
         Entry(.symbol(i), children: (changedOnly ? pruned(i.children) : i.children).map(entry))
     }
     private func pruned(_ items: [OutlineItem]) -> [OutlineItem] {
         items.filter(\.isTouched).map { var c = $0; c.children = pruned(c.children); return c }
     }
     ```
     When `changedOnly == true`, `rebuild()` already prunes `items` via `pruned(items)` (which calls `isTouched`—itself a recursive subtree walk—at every depth), and then `entry(_:)` calls `pruned(i.children)` **again** at every level of the already-pruned tree, resulting in $O(D^3 \cdot N)$ subtree traversals.
  2. **$O(\text{rows})$ scan for `.card` in `show(_:)` and `outlineViewColumnDidResize(_:)` (`Inspector.swift:217, 367-372`)**:
     ```swift
     let cards = IndexSet((0..<outline.numberOfRows).filter { (outline.item(atRow: $0) as? Entry)?.shape == .card })
     if !cards.isEmpty { outline.noteHeightOfRows(withIndexesChanged: cards) }
     ```
     In an overview with 10,000 files or a file with thousands of outline entries, every `show(_:)` and every column-resize pixel scans all 10,000 rows via `outline.item(atRow:)` just to locate the single `.card` row at the bottom of `sections`.
  3. **User-collapsed symbols forcibly re-expanded (`Inspector.swift:258-275`)**:
     `outlineViewItemDidCollapse` only records `sectionTitle` in `folded`. If a user collapses a class or struct symbol in `"Outline"`, `hasCollapsed(section)` (`Inspector.swift:268-270`) returns `true` on the next `rebuild()` and `expandSections()` calls `outline.expandItem(section, expandChildren: true)`, wiping out the user's collapsed state.
  4. **`Entry.fits` conflates different sections (`Inspector.swift:37, 234-251`)**:
     `Entry.fits(_ other: Entry)` only checks `shape == other.shape && children.isEmpty == other.children.isEmpty`. When switching between a changed file (`[.section("Changes"), .section("Outline")]`) and an unchanged file (`[.section("Outline")]`), `merge` mutates the existing `"Changes"` `Entry` in place into `"Outline"`, transferring its expansion state in `NSOutlineView`.
  - Measured by `SidebarsAuditBench` Tests 2a & 2c (`./.build/release/SidebarsAuditBench`):
    ```
    [2a: Inspector changedOnly tree depth=32 (320 nodes)] current=0.1838 ms | fixed(1-pass)=0.0178 ms (10.3x)
    [2c: Inspector card height lookup N= 1000 rows] current(0..<numberOfRows scan)=0.072 ms | fixed(row(forItem: card))=0.0012 ms (60.5x)
    [2c: Inspector card height lookup N=10000 rows] current(0..<numberOfRows scan)=0.640 ms | fixed(row(forItem: card))=0.0010 ms (638.7x)
    ```
- **Fix**:
  1. Build filtered `Entry` nodes in a single bottom-up pass without `pruned` or `isTouched` (**10.3x faster**, $O(N)$).
  2. Look up the card row directly via `outline.row(forItem: cardEntry)` (**639x faster** at 10k rows).
  3. Require `sectionTitle == other.sectionTitle` in `Entry.fits`, and track collapsed symbol identities so `expandSections()` does not re-expand symbols the user collapsed.

---

### Finding 15: `ChangesController.expand` Expands Every Unchanged Subfolder Then Collapses Them One by One When `showsUnchanged == false` and a Folder Is Revealed
- **Location**: `Sources/SextantApp/Navigator.swift:354-374`
- **Category**: Waste / Slowness
- **Plan Step**: Step 3
- **Evidence**:
  In `ChangesController.expand(_ items: [Item])`:
  ```swift
  private func expand(_ items: [Item]) {
      if showsUnchanged {
          expandEach(items)
      } else {
          outline.expandItem(nil, expandChildren: true)
          foldClosed(items)
      }
  }
  ```
  When `showsUnchanged == false` and the user clicks a `.folded` (`"N unchanged"`) item to reveal a large directory (`revealed.insert(i.path)`), `expand` still takes the `else` branch: it calls `outline.expandItem(nil, expandChildren: true)` (which expands **every** unchanged subfolder inside the revealed subtree) and then `foldClosed(items)` walks the tree and calls `outline.collapseItem(i)` one by one on every unchanged subfolder (since `shouldOpen(i)` is `expansion[i.path] ?? (i.changed > 0)` which is `false`), recounting `NSOutlineView` rows on each collapse.
  - Measured by `SidebarsAuditBench` Test 4d (`./.build/release/SidebarsAuditBench`):
    ```
    [4d: ChangesController.expand with 500 revealed unchanged subfolders] current(expandAll+foldClosed)=1.52 ms | fixed(expandEach)=0.082 ms (19x)
    ```
- **Fix**: Always use `expandEach(items)` (or when persistent `Item` nodes are kept across updates in Step 3, only expand newly inserted folders where `shouldOpen(i)` is `true`).

---

### Finding 16: `JumpPanel` Flashes Stale Results on `show(over:)` (Allowing `Return` to Activate a Previous Query's Item) and Runs Full `search()` + `rankJump` After Dismissal When Indexing Finishes
- **Location**: `Sources/SextantApp/JumpPanel.swift:84-133, 183-188` and `Sources/SextantApp/JumpActions.swift:26-44`
- **Category**: Bug / Waste
- **Plan Step**: Step 1 & Step 7
- **Evidence**:
  1. **Stale `items` on `show(over:)` (`JumpPanel.swift:84-97`)**:
     `JumpPanel` is reused across invocations (`let panel = jumpPanel ?? makeJumpPanel()`). When `show(over: parent, text: "")` is called, it orders the panel front (`makeKeyAndOrderFront(nil)`) and starts `search()` asynchronously without clearing `items` or `table`. Until the async `find` task finishes, the panel displays the previous invocation's `items` and height, and if the user types and presses Return before `find` completes (which takes 1.6–4.2 s on large repos), `choose(beside:)` (`JumpPanel.swift:183-188`) selects `items[table.selectedRow]` from the **stale previous search**!
  2. **Post-dismissal background search (`JumpActions.swift:41`, `JumpPanel.swift:116-119`)**:
     When `indexDefinitions` finishes (`JumpActions.swift:41`):
     ```swift
     if self?.session === s { self?.jumpPanel?.progressChanged(foundMore: true) }
     ```
     Unlike `forgetDefinitions` on line 51 (which checks `if jumpPanel?.isVisible == true`), line 41 does **not** check `jumpPanel?.isVisible == true`. If the user already closed `JumpPanel`, `progressChanged(foundMore: true)` still calls `search()`, spawning an uncancelled `Task.detached` `rankJump` over all definitions and calling `table.reloadData()`, `setFrame(..., display: true)`, and `invalidateShadow()` on the hidden panel.
- **Fix**: Guard `guard isVisible else { return }` in `JumpPanel.progressChanged(foundMore:)` (and in `search()`'s completion), and synchronously populate the initial empty-query items (or clear stale items if the query/session changed) in `show(over:text:)`.

---

### Finding 17: `SearchController.begin(_:word:)` Mutates `wholeWord` Without Updating `caseSensitive`, and `focusResults()` Skips Opening the First Search Result on Down Arrow
- **Location**: `Sources/SextantApp/Navigator.swift:597-601, 664, 692-699` and `Sources/SextantApp/WindowActions.swift:227, 269`
- **Category**: Bug
- **Plan Step**: Step 1
- **Evidence**:
  1. When `Find References` (`WindowActions.swift:269`) or `Jump to Definition` fallback (`WindowActions.swift:227`) runs, it calls `navigator.search.begin(word, word: true)`:
     ```swift
     func begin(_ q: String, word: Bool) {
         field.stringValue = q
         wholeWord = word
         summary = "Searching…"
     }
     ```
     `lookUp` always runs `git.grep(name, in: snapshot, word: true, ignoreCase: false)`, which is case-sensitive. However, `begin` does not set `caseSensitive = true`, so `SearchController` highlights the first case-insensitive substring match (`text.range(of: query, options: caseSensitive ? [] : .caseInsensitive)`) in each line instead of the actual identifier, and permanently mutates the user's `wholeWord` setting in the Find bar.
  2. When the user presses Down arrow in the Find field (`Navigator.swift:709` -> `focusResults()` at `Navigator.swift:692-699`):
     ```swift
     func focusResults() {
         view.window?.makeFirstResponder(outline)
         guard outline.selectedRow < 0, let first = (0..<outline.numberOfRows).first(where: { outline.item(atRow: $0) is Item }) else { return }
         suppressOpen = true
         outline.selectRowIndexes([first], byExtendingSelection: false)
         suppressOpen = false
         outline.scrollRowToVisible(first)
     }
     ```
     Because `suppressOpen = true`, selecting row `first` does **not** open it in the reader, whereas pressing Down arrow again moves to the second result and `outlineViewSelectionDidChange` immediately opens the second result. If there is only 1 result, pressing Down arrow in `outline` does nothing because row `first` is already selected.
- **Fix**: Keep programmatic lookup options (`word`, `caseSensitive`) scoped to the displayed results without clobbering the user's Find field toggles, and open the first result (or allow Down arrow / selection to open it consistently) in `focusResults()`.

---

### Finding 18: `TreeCell` & `ProgressPie` Recreate Monochrome SF Symbol `NSImage`s on Every Configure/Draw, `TreeCell.layout()` Runs 3 `sizeToFit()` Calls When `dir` Is Empty, `NoteEditor` Misses Clicks in the Lower Box, and Two Sidebar Tables Omit `look.makeRowView()`
- **Location**: `Sources/SextantApp/Cells.swift:100-123, 241-244`, `Sources/SextantApp/NoteEditor.swift:50-71`, `Sources/SextantApp/Navigator.swift:118`, and `Sources/SextantApp/NotesPane.swift:44`
- **Category**: Waste / Bug
- **Plan Step**: Step 3 & Step 1
- **Evidence**:
  1. **Uncached `NSImage.monochromeSymbol` (`Cells.swift:121-123, 241-244`)**:
     `TreeCell` only uses 5 `(symbolName, themedColor)` combinations (`checkmark.circle.fill`, `circle`, `folder`, `ellipsis`, `square.stack`), and `ProgressPie.draw` uses 1 (`checkmark.circle.fill`). Because `NSColor.themed(...)` is already dynamic per appearance, those 6 `NSImage` instances are constant, yet `TreeCell.configure` and `ProgressPie.draw` allocate a new closure-backed `NSImage` on every cell configuration and draw call.
  2. **Redundant `sizeToFit()` calls in `TreeCell.layout()` (`Cells.swift:100-115`)**:
     In normal tree mode (`showsFolder == false`), `dir.stringValue` is always `""`. Yet `TreeCell.layout()` unconditionally calls `name.sizeToFit()`, `dir.sizeToFit()`, `name.baselineOffsetFromBottom`, and `dir.baselineOffsetFromBottom` on every row layout pass (**75x slower** in `SidebarsAuditBench` Test 7c: `0.01 ms` vs `0.0001 ms` per 1,000 layouts).
  3. **`NoteEditor` text view height (`NoteEditor.swift:50-71`)**:
     `text = NSTextView()` is initialized with `frame: .zero` and `isVerticallyResizable = true` inside a 120pt-tall `NoteTextBox`, without setting `text.minSize = NSSize(width: 0, height: 118)`. For an empty or 1-line note, `text.frame.height` is ~30pt, so clicking in the bottom ~88pt of `NoteTextBox` hits `NSClipView` and fails to focus `text`.
  4. **Inconsistent row selection views (`Navigator.swift:118`, `NotesPane.swift:44`)**:
     `ChangesController.outline`, `SearchController.outline`, and `Inspector.outline` use `look.makeRowView()` (`PillRowView` in `GlassLook`, `ClassicRowView` in `ClassicLook`), whereas `ChangesController.commits` and `NotesPane.table` omit `tableView(_:rowViewForRow:)` and fall back to AppKit's default selection style.
- **Fix**:
  1. Cache monochrome symbol `NSImage`s by `(name, colorKey)` (alongside the `rowViewForItem` reuse fix in Step 1/Step 3).
  2. In `TreeCell.layout()`, when `dir.stringValue.isEmpty`, hide `dir` and set `name.frame` directly to `x0..<right` without calling `name.sizeToFit()` or `dir.sizeToFit()`.
  3. Set `text.minSize = NSSize(width: 0, height: 118)` in `NoteEditor.loadView()`, and return reused `look.makeRowView()` from `tableView(_:rowViewForRow:)` in `ChangesController.commits` and `NotesPane.table`.

---

## 3. Correctness Edge Cases That a Performance Rewrite Could Break

When implementing Steps 1, 3, and 7 across the sidebars and lists, preserve or explicitly fix the following invariants:

1. **Row-view reuse (`rowViewForItem` / `rowViewForRow`) and dynamic appearance/selection**:
   - When changing `outlineView(_:rowViewForItem:)` in `ChangesController`, `SearchController`, and `Inspector` to reuse `PillRowView` / `ClassicRowView` via `outlineView.makeView(withIdentifier:owner:)`, ensure the row view's `identifier` is set in `init` (currently `PillRowView` and `ClassicRowView` have `identifier == nil`, which is why `makeView` couldn't find them if called without setting `identifier`!).
2. **Persistent `ChangesController.Item` nodes and `NSOutlineView` identity**:
   - `NSOutlineView` tracks expanded items and row mappings by object identity (`===`). When Step 3 switches `ChangesController` from full `rebuild()` + `outline.reloadData()` to persistent `Item` nodes with `outline.reloadItem(_:reloadChildren:)`, any folder merge change (`a` -> `a/b`) or `.folded` reveal must update `parent.children` *before* calling `outline.reloadItem(parent, reloadChildren: true)` (or inside `beginUpdates()`/`endUpdates()`), never mutating `children` before `removeItems` as `Inspector.merge` currently does.
3. **Collapsing a folder in `ChangesController` (`itemCollapsed`, `Navigator.swift:380-387`)**:
   - Collapsing a folder `i` subtracts revealed paths under `i.path` (`$0 == i.path || $0.hasPrefix(i.path + "/")`) so re-opening the folder later folds unchanged files back up. If `i` was a merged folder (`name = "a/b"`, `path = "a/b"`), any revealed state on ancestor `"a"` must also be cleaned up.
4. **Multi-commit range selection in `ChangesController.commits` (`Navigator.swift:245-255, 456-460`)**:
   - Selecting multiple commits in `commits` constructs `.commits(newest: newest.oid, oldest: oldest.oid)` spanning `min(commitRows)...max(commitRows)` and calls `showScope(scope)` with `suppress = true` to fill in any discontiguous gap in the selection. Preserving `suppress = true` around programmatic `selectRowIndexes` prevents infinite recursion into `tableViewSelectionDidChange`.
5. **Keyboard focus preservation when stepping through results (`SearchController`, `NotesPane`, `Inspector`)**:
   - In `Inspector.outlineViewSelectionDidChange` (`Inspector.swift:442`) and `NotesPane.tableViewSelectionDidChange` (`NotesPane.swift:103`), selection changes only navigate the reader when the sidebar table itself is `window?.firstResponder`, so `Inspector.follow(lineIndex:)` moving the sidebar selection while the user is typing/moving in `CodeView` never bounces the reader back.
6. **`NSView.textFieldFrame(_:)` pixel alignment on Glass (`Cells.swift:14-16`)**:
   - Manual `layout()` methods in `TreeCell`, `InspectorSectionCell`, `InspectorRowCell`, and `JumpCell` wrap `NSTextField` frames in `textFieldFrame(...)` (`backingAlignedRect(..., options: .alignAllEdgesOutward)`). Removing `textFieldFrame` during layout optimizations will reintroduce the infinite layout loop on `NSGlassEffectView` when fractional scroll offsets land off pixel boundaries.
