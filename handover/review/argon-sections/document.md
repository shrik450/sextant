# Argon Scoped Audit: Per-File Document Model, Layout, Outline, File Tree & Review State (`argon-document`)

Scope:
- `Sources/SextantApp/Document.swift` (`FileState`, `Row`, `Layout`, `layoutRows`, `emptyNotice`)
- `Sources/SextantApp/Notes.swift` (`Note`, `lineReference`, `readingOrder`, `markdown`, `NotesStore`)
- `Sources/SextantApp/ReviewStore.swift` (`ReviewStore`)
- `Sources/SextantCore/WholeFile.swift` (`wholeFile`, `unchangedLinesBefore`, `foldedRuns`)
- `Sources/SextantCore/Reading.swift` (`identifiers`, `landingColumn`, `wholeWordMatches`, `JumpTarget`, `jumpTargets`, `jumpLabels`, `changeKey`, `ReadingState`, `changeStarts`, `changeOrdinal`)
- `Sources/SextantCore/Outline.swift` (`OutlineItem`, `outlineDefinitions`, `inOutline`, `outline`, `changedDefinitions`)
- `Sources/SextantCore/Strip.swift` (`stripOffset`)
- `Sources/SextantCore/FileTree.swift` (`FileNode`, `fileTree`, `ChangeRun`, `changeRuns`)

(Following calls into `Reader.swift`, `CodeView.swift`, `RepoWindowController.swift`, `WindowActions.swift`, `Navigator.swift`, `Inspector.swift`, `NotesPane.swift`, `NoteEditor.swift`, `PaneHeader.swift`, `Panes.swift`, `ContentAnalysis.swift`, `Names.swift`, `Syntax.swift`, `WordDiff.swift`, `Parse.swift`, `Model.swift`.)

All microbenchmarks and adversarial reproduction tests were compiled in release mode against the real `Sources/SextantCore` files and extracted pure logic from `Sources/SextantApp` and live in `/Users/shrik450/Developer/review-ui/scratch/review/argon-sections/document/`.
To rerun all microbenchmarks and adversarial tests:

```bash
cd /Users/shrik450/Developer/review-ui/scratch/review/argon-sections/document && nix develop /Users/shrik450/Developer/review-ui -c swift build -c release && ./.build/release/DocumentAuditBench
```

---

## 1. Architecture Audit

### Ownership and Data Flow
- **`FileState` (`Document.swift:6-429`)**: `@MainActor` reference type owning per-file display and analysis state for one changed file in `Session.changes` or one explored snapshot file in `Session.explored`. Holds:
  - Immutable diff identity: `diff: FileDiff`, `isChange: Bool`, `hasLanguage: Bool`, `contentAnalysis: ContentAnalysis?`.
  - Mutable review/conflict flags: `reviewed: Bool`, `conflicted: Bool`, `unfolded: Set<Int>`.
  - Line buffer state: `lines: [DiffLine]` (initially hunk lines from `diff.hunks`, replaced in-place by `setWhole(_:)` when the whole file is adopted), `isWhole: Bool`, `gapsBefore: [Int: Int]`, `sidesAreBlobs: Bool`, `version: Int`.
  - Async preparation & analysis caches: `wholeLoad: Task<Void, Never>?`, `preparedWhole: (lines: [DiffLine], analysis: Analysis?)?`, `analysis: (task: Task<Void, Never>, symbols: Bool, version: Int)?`, `tokens: [[Token]]?`, `definitions: [Symbol]?`, `outline: [OutlineItem]?`, `hasTags: Bool?`, `names: (new: SideNames, old: SideNames?)?`, `naming: (task: Task<Void, Never>, version: Int)?`, `words: [Int: [NSRange]]?`, `runs: [KeyedRun]?`.
- **`Row`, `Layout`, `layoutRows`, `emptyNotice` (`Document.swift:432-522`)**: Pure transformation from `([FileState], overview, split, showAll, [Note])` into 1-column (`left`) or 2-column (`left`, `right`) `[Row]` sequences consumed by `Reader.reload` (`Reader.swift:287`) and `CodeView.render` (`CodeView.swift:81`).
- **`Notes.swift`**: `Note` value model (`id`, `subject`, `lines: Note.Lines?`, `text`, `created`), `lineReference`, `readingOrder`, `markdown`, and `@MainActor final class NotesStore` (per-`commonDir` singleton persisting `<commonDir>/sextant/notes.json` and broadcasting `NotesStore.didChange`).
- **`ReviewStore.swift` & `ReadingState` (`Reading.swift:127-166`)**: `ReadingState` value struct (`reviewed: Set<String>`, `read: Set<String>`) and `@MainActor final class ReviewStore` (per-`commonDir` singleton persisting `<commonDir>/sextant/reviewed.json` and `read.json` and broadcasting `ReviewStore.didChange`).
- **`WholeFile.swift`**: Pure functions expanding `[Hunk]` + `oldLines: [String]` into whole-file `[DiffLine]` (`wholeFile`), computing inter-hunk skipped line counts (`unchangedLinesBefore`), and finding foldable context runs (`foldedRuns`).
- **`Outline.swift`**: Pure functions filtering function-local symbols (`inOutline`, `outlineDefinitions`), diffing old and new `[Symbol]` against `[DiffLine]` to build a nested `[OutlineItem]` tree (`outline`), and filtering for directly touched items (`changedDefinitions`).
- **`Reading.swift`**: Pure functions for line-level identifier extraction (`identifiers`, `landingColumn`), word matching (`wholeWordMatches`), 2-char jump target search and labeling (`jumpTargets`, `jumpLabels`), FNV-1a change-run hashing (`changeKey`), `ReadingState`, and binary search over change-start rows (`changeStarts`, `changeOrdinal`).
- **`FileTree.swift`**: Pure functions building `[FileNode]` folder/file/unchanged trees for the navigator (`fileTree`, `Folder`) and grouping consecutive changed `DiffLine`s into `[ChangeRun]` (`changeRuns`).
- **`Strip.swift`**: Pure horizontal scroll-offset calculation for the pane strip (`stripOffset`).

### What Is in the Wrong Place or Duplicated
1. **`ChangeRun` and `changeRuns(_:)` live in `FileTree.swift` (`FileTree.swift:115-143`)**:
   - `ChangeRun` has nothing to do with `FileTree`; it is a per-file diff-line run model used by `Outline.swift` (`changedSpans`, `Outline.swift:102`) and `Document.swift` (`FileState.keyedRuns`, `Document.swift:356`). It belongs in `WholeFile.swift` or `Reading.swift`.
2. **Three separate change-run / changed-line-pair scanners over `[DiffLine]`**:
   - `changeRuns(_:)` (`FileTree.swift:127`) scans `lines` for consecutive non-`.context` runs.
   - `pairChangedLines(_:)` (`WordDiff.swift:64`) scans `lines` for consecutive `.deleted` then `.added` runs.
   - `layoutRows` (`Document.swift:488-495`) scans `lines` for consecutive `.deleted` then `.added` runs (and is the **only** one of the three that checks `gapsBefore` and `foldAt`).
   - Neither `changeRuns` nor `pairChangedLines` checks `gapsBefore`, so in hunk-only mode (`!isWhole`) they merge adjacent hunks into a single run/pair if a hunk boundary has no intervening `.context` line.
3. **Duplicate identifier-character classification across 4 files**:
   - `Reading.swift:3-6` (`isIdentifierUnit`): `CharacterSet.alphanumerics.contains(s) || s == "_" || s == "$"`.
   - `CodeView.swift:1022-1025` (`CodeView.identifier(at:)`): `CharacterSet.alphanumerics.contains(u) || u == "_" || u == "$"`.
   - `Reader.swift:441` (`Reader.highlightUses`): `w.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" })`.
   - `WindowActions.swift:389` (`symbolAtCaret`): `w.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "$" })`.
   - `WordDiff.swift:8` (`wordTokens`): `(c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127` (omits `$` `36`!).
4. **Dead / unwired code in `Document.swift`**:
   - `FileState.generatedNames` and `FileState.isGenerated` (`Document.swift:104-113`) are defined on `FileState` (listing lockfiles, `.min.js`, `.min.css`, `.pbxproj`) but **never called anywhere in the repository**.
   - `FileState.sideText(old:)` (`Document.swift:393-395`) is **never called anywhere in the repository**.
5. **Grammar loading coupled to Markdown formatting (`Notes.swift:57`, `WindowActions.swift:381`)**:
   - `markdown(_:)` and `copyReferenceWithCode` call `SyntaxRuntime.shared?.language(forPath: path)?.name`, which synchronously `dlopen`s the grammar dylib, hashes 4 files with SHA-256, and compiles `highlights.scm`, `tags.scm`, and `locals.scm` on the main thread just to read the static language name string from `languages.json`.

### Invariants Nothing Enforces
1. **`DiffLine.oldNo` is `0` on `.added` lines and `DiffLine.newNo` is `0` on `.deleted` lines (`Parse.swift:202-216`)**:
   - Nothing in `DiffLine`'s type or `FileState` prevents callers from treating `oldNo` or `newNo` as a valid 1-based line number on all lines or assuming `lines` is sorted by `oldNo`/`newNo` without zeros.
   - As proven in Findings 3 and 7 below, this breaks `Reader.stepDefinition`, `Reader.currentNewLine`, `WindowActions.goToLine`, and `wholeFile` on combined diffs.
2. **`FileState.isWhole` conflates "hunks are empty because the file has no content" with "hunks are empty because no lines changed" (`Document.swift:59`)**:
   - `isWhole` is initialized to `true` whenever `diff.hunks.isEmpty`, which is true for pure renames (`R100`) and mode-only changes (`100644 -> 100755`) on non-empty files. Nothing enforces that `isWhole == true` implies `lines` actually holds the blob's lines (Finding 1).
3. **`FileState` mutates `lines` in-place from hunk-only to whole-file while multiple panes can share the same `Session` (`RepoWindowController.swift:283, 381-385`)**:
   - Multiple `Pane`s viewing the same `Review` share the same `Session` and the same `[FileState]` instances (`s.changes`).
   - If Pane 1 is showing Overview (expecting `f.lines` to remain hunk-only or laid out with its current `Layout.left`/`right` row indices, where `Row.line` is an index into `f.lines`!) and the user opens `f` in Pane 2 (`open` -> `f.adoptWhole()` -> `f.setWhole(...)`), `f.lines` is replaced in-place with the whole file's lines while **Pane 1's `CodeView.rows` still holds `Row(kind: .line, file: fi, line: oldHunkLineIndex)`**!
   - When Pane 1 subsequently scrolls, colors visible rows (`CodeView.color(row:_:)` indexing `f.lines[row.line]` and `f.tokens?[row.line]`), or draws the gutter (`CodeView.line(ofRow:)` indexing `files[rows[r].file].lines[rows[r].line]`), Pane 1 indexes into the **new whole-file `f.lines`** using **stale hunk-only indices**, coloring the wrong lines and displaying the wrong line numbers in the gutter!
4. **Side-by-side `Layout.left` and `Layout.right` assume 1:1 vertical row-height correspondence, which nothing enforces (`Document.swift:448-510`, `CodeView.swift:124-126`)**:
   - `Reader.scrolled` syncs `clip.bounds.origin.y` directly between the two columns. Any row whose left and right strings produce a different number of line fragments in `NSLayoutManager` (such as a multi-line `.note` row or a wrapped code line when `wraps == true`) permanently desynchronizes vertical alignment for the rest of the document (Finding 4).
5. **`OutlineItem.contains` and `nest` assume deleted definitions (`span = at...at`) cannot sit at the same `lowerBound` as an added/modified container (`Outline.swift:31-34, 77-86, 105-116`)**:
   - Nothing enforces that inserting synthetic zero-width deleted items into `items` preserves the laminar containment order required by `nest`'s contiguous `while head.contains(items[j])` loop (Finding 2).

### Fit with the Target Design (`scratch/perf/plan.md`)
- **Step 1 (Confirmed & newly discovered correctness bugs)**:
  - Fix `FileState.init`'s `isWhole` for pure renames/mode changes (Finding 1), `Outline` nesting barrier and same-named symbol collisions and pure-deletion span off-by-one (Finding 2), `.deleted` line `newNo == 0` bugs in `stepDefinition`/`currentNewLine`/`goToLine` (Finding 3), Side-by-Side multi-line note vertical desync and note placement (Finding 4), `changeKey` collisions on identical hunks in the same file (Finding 5), `FileTree` dropping revealed folders and hiding unchanged files in merged folders (Finding 6), `FileState.reference` dropping deleted lines (Finding 7), `Reader.reload(keepPosition: true)` unfolding when toggling `showAll` off (Finding 8), and non-BMP UTF-16 surrogate pair handling in `identifiers`/`wholeWordMatches` (Finding 12).
- **Step 2 (Limits & lifetimes)**:
  - Wire up size/line-width admission limits in `FileState` (using/expanding the currently dead `FileState.isGenerated` + the plan's ~2 MB / 20,000 UTF-16 unit per-line syntax cutoff and ~50 MB / 1M-line preview cutoff).
  - Decouple `prepareWhole` line loading from `FileState.analyze` so `open()` never awaits background neighbor tree-sitter parses (Finding 9), and cancel superseded `analysis`, `naming`, and `wholeLoad` tasks on `setWhole` / navigation.
  - Evict `FileState.names`, `tokens`, `words`, and whole-file `lines` for off-screen files via the byte-bounded LRU instead of retaining them forever on `Session.changes` and `Session.explored`.
- **Step 3 (Cheap UI fast paths)**:
  - Stop calling `p.reader.reload(keepPosition: true)` on `reviewsChanged` in Overview (Finding 10) and stop calling `reload` on unaffected panes in `notesChanged`.
  - Pre-group `notes` by `path` and binary-search line numbers in `layoutRows` (Finding 13); binary-search `keyedRuns` and store `reviewKey` on `RawChange` / `FileState` (Finding 14).
  - Replace `FileTree`'s per-event full 300k-path rebuild and `localizedStandardCompare` sort with a persistent snapshot tree node structure where review toggles update only ancestor counts in $O(\text{depth})$ (Finding 11).
  - Move `ReviewStore` and `NotesStore` persistence off the main actor with coalesced writes, and only write the file (`reviewed.json` vs `read.json`) that actually mutated (Finding 15).
- **Step 6 (Content analysis)**:
  - Run a single tree-sitter parse per blob that produces tokens, definitions (`Symbol`), and local scopes (`LocalCaptures`) in one pass rather than parsing once for `analyze(symbols: false)`, a second time for `analyze(symbols: true)`, and a third time for `indexNames()` (Finding 16).

---

## 2. Efficiency Summary

| Operation / Component | Current Work & Allocations | Complexity | Measured Cost / Bottleneck |
| :--- | :--- | :--- | :--- |
| `fileTree` (`FileTree.swift:34-112`) | Splits every snapshot path into `[Substring]` + `[String]`, inserts into `Folder` hash trees, walks all $N$ paths concatenating `prefix + name`, sorts all folders & files with `localizedStandardCompare` **before** filtering `changed > 0` | $O(N_{\text{paths}} \cdot \text{depth} \cdot \log(\text{branching}))$ on **main thread** | **9.47 ms** (10k), **98.18 ms** (100k), **296.11 ms** (300k paths, 10 changed, `showUnchanged=false`) on every review toggle, scope change, or snapshot load. |
| `Reader.stepChangedDefinition` + `changedDefinitions` (`Outline.swift:81-99`, `Reader.swift:844-853`) | Recomputes `changedDefinitions` (scanning every line of `shared` against `item.children`), then runs `f.lines.firstIndex` per changed definition | $O(D_{\text{changed}} \times L_{\text{lines}} + L_{\text{span}} \times C_{\text{children}})$ on **main thread** | **684.79 ms** per `]d`/`[d` keypress on a 50k-line file with 1,000 changed methods (`changedDefinitions` alone takes **6.46 ms** on a contiguous span). |
| `identifiers(in:tokens:)` & `landingColumn` (`Reading.swift:3-53`) | Bridges `UnicodeScalar(u)` + `CharacterSet.alphanumerics.contains` per UTF-16 unit; filters `skipped` array; scans `skipped` linearly per identifier | $O(L_{\text{utf16}} + I_{\text{idents}} \times T_{\text{skipped}})$ on **main thread** | **2.19 ms** at 15k chars / 1.5k tokens; **43.71 ms** at 80k chars / 7.5k tokens; ASCII/bitmap + two-pointer scan takes **0.145 ms** (**301.4x faster**). Also called on **every line of both sides** inside `NameIndex.candidates` (`Names.swift:179`). |
| `layoutRows` + `FileState.anchor(of:)` (`Document.swift:423-510`) | Loops all `notes` for every file (`O(F * N)`), runs `lines.firstIndex` per note (`O(L)`), appends to unused `right: [Row]` in Unified mode, scans `lines.contains` for `isTwoSided` | $O(F \times N_{\text{notes}} \times L + \text{total lines})$ on **main thread** | **11.90 ms** for 5k files with 100 notes (vs **4.45 ms** pre-grouped, **2.7x faster**); **0.68 ms** vs **0.07 ms** (**9.4x faster**) on 1x 50k-line file with 50 notes. |
| `ReviewStore.update` + `ReadingState.setReviewed` (`Reading.swift:159-165`, `ReviewStore.swift:50-67`) | Allocates `prefixes`, filters entire `read` set (`O(read * files)`), sorts and pretty-prints **both** `reviewed.json` and `read.json` synchronously on main | $O(|R_{\text{read}}| \times |F| + (|R_{\text{rev}}| \log |R_{\text{rev}}| + |R_{\text{read}}| \log |R_{\text{read}}|))$ on **main thread** | **96.53 ms** (`40.00 ms` filter + `56.53 ms` sort/encode) on main thread at 50k historical keys, plus 2 atomic disk writes on every `R` press. |
| `FileState.run(at:)` + `RawChange.reviewKey` (`Document.swift:361`, `Model.swift:31`, `CodeView.swift:338, 691`) | Linear scan `keyedRuns.first` + heap string interpolation of `reviewKey` on every changed line during `color()` and every `drawBackground()` frame | $O(R_{\text{runs}})$ per changed line | **1.11 ms** for 2,000 changed lines; binary search + cached `reviewKey` takes **0.209 ms** (**5.3x faster**) with zero heap allocations. |
| `FileState.analyze` + `indexNames` (`Document.swift:145, 208-291`, `Names.swift:262-277`) | Up to 6 full tree-sitter parses of a modified file (2 hunk sides + 2 whole sides with `symbols: false` + 2 with `symbols: true` + 2 in `indexNames` + $O(I \cdot \text{depth})$ `root.descendant` calls) | $O(\text{file bytes} + I \cdot \text{tree depth})$ | Redundant parses of identical text; `prepareWhole(analyzing: true)` blocks `open()` until both sides finish parsing. |

---

## 3. Ranked Findings (Bugs, Slowness, Waste, Architecture)

*Note: Known findings already listed in `scratch/perf/plan.md` are not re-reported unless refined below with new root causes, failure modes, or benchmark measurements.*

---

### Finding 1 (Bug — High Impact): Purely renamed (`R100`) and mode-changed (`100644 -> 100755`) files set `isWhole = true` with `lines = []`, making their contents impossible to open, read, or jump into
- **Location**: `Sources/SextantApp/Document.swift:59`, `Document.swift:136, 141`, `Sources/SextantApp/RepoWindowController.swift:519-534`
- **Category**: Bug
- **Plan Step**: Step 1 (Confirmed bugs) & Step 2 (Lazy whole-blob loading)
- **Evidence**:
  In `FileState.init(diff:isChange:contentAnalysis:)` (`Document.swift:59`):
  ```swift
  isWhole = diff.hunks.count <= 1 && gaps.isEmpty && (diff.change.isAdded || diff.change.isDeleted || diff.hunks.isEmpty)
  ```
  When a non-empty file is renamed without content changes (`status == "R"`, `score == 100`, `oldOid == newOid != zeroOid`) or has only a file mode change (`100644 -> 100755`), `diff.hunks` is empty (`diff.hunks.isEmpty == true`).
  1. `FileState.init` sets `lines = []` and **`isWhole = true`** (so `hasWhole` is also `true`).
  2. When the user clicks the file in the Navigator, clicks its header in Overview, or triggers **Jump to Definition** into a symbol defined in that renamed/mode-changed file (`RepoWindowController.swift:519-534`):
     - `readyFile` finds the `FileState` in `s.changes`, sees `f.hasWhole == true`, and immediately presents `f` with `f.lines = []`.
     - Even if `prepareWhole` is called (`Document.swift:141`), `guard !hasWhole, !diff.isBinary else { return }` returns immediately without reading the blob.
     - `f.index(ofLine: targetLine)` returns `nil`, and the single-file reader displays only `"Renamed without changes"` or `"Mode changed from 100644 to 100755"` with no code, no outline, and no way to view the file anywhere in the review.
  3. Conversely, for a small modified file (`status == "M"`) whose single hunk already covers the entire file (`@@ -1,3 +1,3 @@`, `gaps.isEmpty == true`), `isWhole` is set to **`false`**, forcing `open()` to spawn an async `git.oldLines` + `wholeFile` reload that produces the exact same `lines` array (`f.lines == wholeFile`) and calls `setWhole`, wiping out `tokens`, `definitions`, `outline`, `words`, `names`, and `runs` (`Document.swift:120-133`).
  - **Reproduction output from `DocumentAuditBench` (`[Test B]` & `[Test C]`)**:
    ```text
    [Test B - Pure rename (R100) and mode-only change set isWhole=true with empty lines]
      renameState: isWhole=true lines.count=0 index(ofLine: 50)=nil
      modeState:   isWhole=true lines.count=0 index(ofLine: 50)=nil
    [Test C - Small modified file where 1 hunk is already whole]
      f.isWhole=false f.sidesAreBlobs=false f.lines == wholeFile: true
    ```
- **Fix**:
  1. In `FileState.init`, `diff.hunks.isEmpty` only means `isWhole = true` when the file actually has no content (i.e., `emptyBlobOid = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"` or `zeroOid` on both sides, or submodule `160000`, or status `"U"`). For a rename or mode change with a non-empty blob OID, `isWhole` must start as `false` so opening the file in single-file view (or jumping to a line in it) loads the blob via `prepareWhole`.
  2. In `layoutRows` (`Document.swift:456`), when `overview == true` and `!f.hasOldSide && !f.hasNewSide`, show `emptyNotice(f)` in the overview even if `f.isWhole` was loaded for single-file reading.
  3. In `setWhole(_ all: [DiffLine])`, if `all == lines`, set `isWhole = true; sidesAreBlobs = true; gapsBefore = [:]` without wiping `tokens`, `definitions`, `outline`, `words`, `names`, or `runs`.

---

### Finding 2 (Bug — High Impact): Four compounding bugs in `Outline.swift`: deleted definitions act as a barrier that ejects all children of a new/renamed container to the top level; same-named methods in different types collide; pure deletions mark the wrong function as `.modified`; and deleted containers never nest
- **Location**: `Sources/SextantCore/Outline.swift:31-34`, `Outline.swift:46-53`, `Outline.swift:65-88`, `Outline.swift:101-116`, `Sources/SextantApp/Document.swift:235`, `Sources/SextantCore/FileTree.swift:139`
- **Category**: Bug
- **Plan Step**: Step 1 (Confirmed bugs) & Step 6 (Content)
- **Evidence**:
  1. **Deleted definition at the same start line acts as a nesting barrier in `nest` (`Outline.swift:31-34, 77-86, 105-116`)**:
     When a type/container `StructB` (old lines `10...14`) is replaced or renamed at the same line by `StructC` (new lines `10...14`, containing child method `configure` at `11...13`):
     - `StructB` gets `change = .deleted` and `span = 10...10` (`at = newLineOfOld(10) = 10`).
     - `sorted` (`Outline.swift:77-84`) orders `StructC` (`10...14`) first, `StructB` (`10...10`, `.deleted`) second, and `StructC.configure` (`11...13`) third.
     - In `nest` (`Outline.swift:105-116`), `head` is `StructC` (`10...14`), and `j = i + 1` is `StructB` (`10...10`, `.deleted`).
     - `head.contains(StructB)` (`Outline.swift:33`) checks `other.change == .deleted ? span.lowerBound < other.span.lowerBound : ...` (`10 < 10`), which is **`false`**!
     - The contiguous loop `while j < items.endIndex, head.contains(items[j]) { j += 1 }` stops immediately at `StructB` (`j = i + 1`), giving `StructC` **`children = []`** and ejecting all of `StructC`'s methods (`configure` at `11...13`) to the **top level** of the file outline!
  2. **Keying `oldKeys` and `newKeys` only by `"\(s.kind) \(s.name)"` without enclosing scope (`Outline.swift:67-76`)**:
     - If `StructA` has `func configure()` (untouched) and `StructB` (deleted) also had `func configure()`, `newKeys` still contains `"method configure"` (from `StructA`), so `StructB.configure` is **silently omitted** from the deleted items in the outline.
     - If `StructC` (added) defines `func configure()`, `oldKeys` contains `"method configure"` (from `StructA`), so `StructC.configure` is misclassified as **`.modified` instead of `.added`**.
  3. **Pure deletion at the end of a function or before an untouched function marks the wrong function as `.modified` (`FileTree.swift:139`, `Outline.swift:69, 101-103`)**:
     - In `changeRuns` (`FileTree.swift:139`), for a pure deletion (`firstAdded == nil`), `newLine` is set to `start > 0 ? lines[start - 1].newNo : 0`. Because `lines[start - 1].newNo` is 1-based, `newLine` is the **0-based new-side line AFTER `lines[start - 1]`** (i.e. the line following the deletion).
     - `changedSpans` (`Outline.swift:102`) turns that 0-addition run into the 1-line new-side range `newLine...newLine`.
     - If the last statement of a Python/YAML/Markdown function `def foo():` (0-based new lines `0...1`) is deleted right before an untouched `def bar():` (0-based new lines `2...3`), `newLine` is `2`, so `changedSpans` is `[2...2]`.
     - `[2...2]` does **not** overlap `foo` (`0...1`), so the modified `foo` is marked **`.none`**, while `[2...2]` **does** overlap the first line of `bar` (`2...3`), so the completely untouched `bar` is marked **`.modified`**! (The same false `.modified` happens in Swift/Rust whenever a comment or blank line immediately above `func bar()` is deleted.)
  4. **Deleted files have `definitions = []` (`Document.swift:235`), and deleted containers cannot nest children (`Outline.swift:32`)**:
     - In `FileState.analyze` (`Document.swift:235`), `Analysis.definitions` is always `new.definitions` (which is `[]` on a deleted file), leaving the header symbol picker and `stepDefinition` empty on deleted files.
     - In `OutlineItem.contains` (`Outline.swift:32`), `guard change != .deleted` prevents any deleted struct/class from nesting its deleted methods.
  - **Reproduction output from `DocumentAuditBench` (`[Test D1]` & `[Test D2]`)**:
    ```text
    [Test D1 - Outline bugs (same-named methods & deleted struct barrier)]
      top-level: struct StructA change=none span=0...9 children=["method configure (none)"]
      top-level: struct StructC change=added span=10...14 children=[]
      top-level: struct StructB change=deleted span=10...10 children=[]
      top-level: method configure change=modified span=11...13 children=[]
      top-level: function bar change=none span=15...19 children=[]
    [Test D2 - Pure deletion at end of Python def foo() right before untouched def bar()]
      function foo: change=none (expected foo=modified, bar=none!)
      function bar: change=modified (expected foo=modified, bar=none!)
    ```
- **Fix**:
  1. Nest `old` symbols into an old-side hierarchy and `new` symbols into a new-side hierarchy *before* matching them (keying each symbol by its qualified path `(enclosingKind, enclosingName, kind, name)`), or in `OutlineItem.contains` allow `span.lowerBound <= other.span.lowerBound` for `.deleted` items when `other.span != span` and sort top-level `.deleted` siblings outside the container's span.
  2. Determine whether a symbol `s` in `new` is `.modified` by checking whether the `DiffLine` range corresponding to `s.lines` (between the first `DiffLine` with `newNo == s.lines.lowerBound + 1` and the last `DiffLine` with `newNo == s.lines.upperBound + 1`, plus any immediately trailing `.deleted` lines whose `oldNo - 1` was inside the old symbol's `s.lines`) contains any `.added` or `.deleted` `DiffLine`, rather than synthesizing a 1-line new-side span on the line after a deletion.
  3. For deleted files (`diff.change.isDeleted`), populate `definitions` from `old.definitions` and preserve old-side spans on deleted outline items so nesting and `Inspector.follow` work on deleted code.

---

### Finding 3 (Bug — High Impact): `.deleted` lines have `newNo == 0`, breaking `Reader.stepChangedDefinition` (685 ms main-thread stall), `Reader.stepDefinition` (jumps to line 0), `Reader.currentNewLine` (wrong breadcrumb symbol), and `WindowActions.goToLine` (clamps max line number)
- **Location**: `Sources/SextantApp/Reader.swift:837, 844-853, 886-890`, `Sources/SextantApp/WindowActions.swift:565`, `Sources/SextantCore/WholeFile.swift:18-23`
- **Category**: Bug & Slowness
- **Plan Step**: Step 1 (Confirmed bugs) & Step 3 (Cheap UI fast paths)
- **Evidence**:
  Every `.deleted` `DiffLine` created by `parseFilePatch` (`Parse.swift:204, 212`) has `newNo = 0` (and in combined `@@@` diffs, `oldNo = 0` as well).
  1. **`Reader.stepDefinition` (`Reader.swift:837`) jumps to the top of the file whenever the caret is on a deleted line**:
     ```swift
     let here = caret.map { f.lines[$0.line] }.map { $0.kind == .deleted ? max(0, $0.newNo) : $0.newNo - 1 } ?? currentNewLine ?? 0
     ```
     When the caret is on any `.deleted` line (even at line 5,000), `$0.newNo` is `0`, so `here` evaluates to **`0`**. Pressing Next Definition (`]d`) jumps back to the first definition at the top of the file; pressing Previous Definition (`[d`) beeps and fails to move.
  2. **`Reader.currentNewLine` (`Reader.swift:889`) returns `oldNo - 1` as if it were a new-side line number**:
     ```swift
     return p.map { f.lines[min($0.line, f.lines.count - 1)] }.map { $0.newNo > 0 ? $0.newNo - 1 : max(0, $0.oldNo - 1) }
     ```
     `updateHeader()` passes `currentNewLine` to `header.updateSymbol(line:)`, which compares it against `definitions` (new-side `Symbol.lines`). Whenever earlier hunks added or removed lines, `oldNo - 1` is offset from new-side line numbers, so the header displays the wrong enclosing function when the caret is on a deleted line.
  3. **`WindowActions.goToLine` (`WindowActions.swift:565`) clamps the file's maximum line number to the last deleted line's `oldNo`**:
     ```swift
     let last = f.lines.last.map { max($0.newNo, $0.oldNo) } ?? 1
     ```
     If a 50-line file had 450 lines added and its last line (`oldNo = 50, newNo = 0`) deleted at EOF, `f.lines.last` is that deleted line, so `last` is **`50`** even though the new file has **499 lines** (`min(n, last)` prevents jumping past line 50).
  4. **`wholeFile` on a combined diff (`@@@`, where `l.oldNo == 0`) duplicates the old file (`WholeFile.swift:18-23`)**:
     In `wholeFile`, `if l.oldNo > 0 { nextOld = l.oldNo + 1 }` never advances `nextOld` when `l.oldNo == 0`, so `context(through: old.count)` after the hunk re-emits all old lines starting from `h.oldStart`.
  5. **`Reader.stepChangedDefinition` (`Reader.swift:844-853`) runs in $O(D_{\text{changed}} \times L_{\text{lines}})$ on the main thread**:
     For every item in `changedDefinitions(in: f.outline ?? [], lines: f.lines)`, it runs `f.lines.firstIndex { ... }`. On a 50k-line file with 1,000 changed methods, a single `]d` keypress stalls the main thread for **684.79 ms** (`DocumentAuditBench [Bench 5]`).
- **Fix**:
  1. Store the `DiffLine` index (into `f.lines`) directly on each `OutlineItem` when `outline(lines:new:old:)` constructs it, so `stepChangedDefinition`, `stepDefinition`, and `Inspector.activate` jump in $O(1)$ without scanning `f.lines`.
  2. Give `.deleted` lines the 1-based `newNo` of the new-side position where they sit (or provide `f.newLineNumber(at: lineIndex)` that walks to the nearest non-deleted neighbor), and compute `goToLine`'s `last` from the last non-deleted line's `newNo` and last non-added line's `oldNo`.
  3. In `wholeFile` (`WholeFile.swift:17-24`), advance `nextOld = max(nextOld, h.oldEnd)` and `nextNew = max(nextNew, h.newEnd)` at the end of each hunk.

---

### Finding 4 (Bug — High Impact): Side-by-Side mode vertically desynchronizes the left and right columns after any multi-line note, and places notes at the bottom of the entire change run instead of beside their anchored line
- **Location**: `Sources/SextantApp/Document.swift:469-471, 496-504`, `Sources/SextantApp/CodeView.swift:123-126`, `Sources/SextantApp/Reader.swift:752-757`
- **Category**: Bug
- **Plan Step**: Step 1 (Confirmed bugs) & Step 3 (Cheap UI fast paths)
- **Evidence**:
  1. **Multi-line note vertical desynchronization (`CodeView.swift:123-126`)**:
     In `layoutRows`, `emitNotes(after: i)` calls `both(Row(kind: .note(n.id), file: fi, line: i))`, putting `.note(id)` at the same row index in both `left` and `right`.
     Then `render` (`CodeView.swift:124-125`) formats `.note(id)` as:
     ```swift
     let anchoredSide = files[row.file].lines[row.line].kind == .deleted ? 0 : 1
     s = side < 0 || side == anchoredSide ? (notes[id]?.text ?? "").replacingOccurrences(of: "\n", with: "\u{2028}") : ""
     ```
     When a note's text contains $K$ newlines `\n` (converted to `\u{2028}` Unicode line separators):
     - On `anchoredSide`, TextKit lays out **$K + 1$ line fragments** of height $(K + 1) \times \text{lineHeight}$.
     - On the opposite side (`side != anchoredSide`), `s` is `""`, which has **0 line breaks** and lays out **1 line fragment** of height $1 \times \text{lineHeight}$!
     Because `Reader.scrolled` (`Reader.swift:754`) synchronizes raw `clip.bounds.origin.y` between the two columns, **every row after the note is permanently shifted vertically by $K \times \text{lineHeight}$ pixels between the left and right columns**.
  2. **Side-by-Side note emitted at the bottom of the entire change run (`Document.swift:496-504`)**:
     ```swift
     for k in 0..<max(dels.count, adds.count) {
         left.append(k < dels.count ? Row(kind: .line, file: fi, line: dels[k]) : Row(kind: .filler, file: fi))
         right.append(k < adds.count ? Row(kind: .line, file: fi, line: adds[k]) : Row(kind: .filler, file: fi))
     }
     for d in dels { emitNotes(after: d) }
     for a in adds { emitNotes(after: a) }
     ```
     If a change run replaces 50 lines with 50 lines and the reviewer adds a note on the **first** line (`dels[0]` or `adds[0]`), `layoutRows` emits all 50 side-by-side line rows first and emits the note **at the bottom of the 50-line block**, 49 lines below the line it was anchored to (see `DocumentAuditBench [Test F2]`, where a note on `del 2` at row 1 is emitted at row 4 after `del 3` and `add 4`).
- **Fix**:
  1. In `layoutRows` (`Document.swift:496-504`), emit notes for `dels[k]` and `adds[k]` immediately after pair `k` inside the `for k in 0..<max(dels.count, adds.count)` loop.
  2. In `CodeView.render` (`CodeView.swift:123-126`), when `side >= 0 && side != anchoredSide`, emit the same number of `\u{2028}` line breaks (i.e. `String(repeating: "\u{2028}", count: noteText.utf8.filter { $0 == 0x0A }.count)`) so both columns always have identical row height.

---

### Finding 5 (Bug — High Impact): `changeKey` hashes only line kind and text, so identical change runs in the same file collide — marking the first run as read marks all identical runs as read and prematurely marks the whole file as reviewed
- **Location**: `Sources/SextantCore/Reading.swift:109-125`, `Reading.swift:148-156`, `Sources/SextantApp/Document.swift:353-358`, `Sources/SextantApp/WindowActions.swift:426-435`
- **Category**: Bug
- **Plan Step**: Step 1 (Confirmed bugs)
- **Evidence**:
  In `Reading.swift:109-125`, `changeKey(file:lines:)` computes an FNV-1a hash of only `(line.kind, line.text)` for the lines in a `ChangeRun`.
  When a file has two or more change runs with the same line change (e.g., adding `guard isReady else { return nil }`, renaming an identifier, or deleting a blank line in two functions):
  1. `f.keyedRuns` (`Document.swift:356`) assigns the **exact same `key` string** to both runs.
  2. When the user presses Mark Change as Read on the first run (`WindowActions.swift:429`), `reviews.setRead(run.key, in: f.diff.change, all: f.keyedRuns.map(\.key), to: true)` inserts `run.key` into `read`.
  3. Both runs now satisfy `read.contains(key)`. If those were the only two unread runs in the file, `all.allSatisfy(read.contains)` (`Reading.swift:150`) immediately evaluates to **`true`**, marking the **entire file as reviewed (`reviewed = true`)** and failing to advance the caret to the second run (`unread` is empty at `WindowActions.swift:431`)!
  - **Reproduction output from `DocumentAuditBench` (`[Test A]`)**:
    ```text
    [Test A - changeKey collision on identical hunks in same file]
      runs.count=2 run0.key==run1.key: true
      After marking ONLY run 0 as read: isRead(run1)=true, isReviewed(file)=true
    ```
- **Fix**:
  Disambiguate duplicate keys within a file in `FileState.keyedRuns` (or pass an occurrence ordinal / the run's first line number into `changeKey`) so every `ChangeRun` in a file has a distinct key. Also guard `!all.isEmpty` before `all.allSatisfy(read.contains)` in `ReadingState.setRead` (`Reading.swift:150`).

---

### Finding 6 (Bug — Medium-High Impact): `fileTree` hides unchanged files in merged intermediate folders without emitting an `.unchanged` row, and ignores `revealed` when merging single-child folders
- **Location**: `Sources/SextantCore/FileTree.swift:78-111`
- **Category**: Bug
- **Plan Step**: Step 1 (Confirmed bugs) & Step 3 (Persistent navigator nodes)
- **Evidence**:
  In `Folder.node` and `Folder.mergedChild` (`FileTree.swift:89-111`):
  ```swift
  func node(name: String, path: String, showAll: Bool, revealed: Set<String>, changed: Set<String>, reviewed: Set<String>) -> FileNode {
      if let (childName, child) = mergedChild(path: path, showAll: showAll, changed: changed) {
          var n = child.node(name: childName, path: path + "/" + childName, showAll: showAll, revealed: revealed, changed: changed, reviewed: reviewed)
          n.name = name + "/" + n.name
          return n
      }
  ```
  1. **Unchanged files in merged parent folders disappear with no `.unchanged(Int)` row**:
     When `showUnchanged == false` and a repository has `a/readme.md` (unchanged), `a/b/notes.txt` (unchanged), and `a/b/c/changed.swift` (changed):
     - `a` has no changed files of its own and 1 subfolder `b` with `changed > 0`, so `mergedChild` merges `a` into `b`, and `b` into `c`, producing a single folder node `name = "a/b/c", path = "a/b/c"`.
     - `nodes(...)` is only called on `c` (which has 0 unchanged files of its own).
     - Neither `a/readme.md` nor `a/b/notes.txt` gets an `.unchanged` row anywhere in the tree! There is no pill to click to reveal them.
  2. **`mergedChild` ignores `revealed.contains(path)`**:
     Because `node(...)` calls `mergedChild(...)` before `nodes(...)` and `mergedChild` does not check `!revealed.contains(path)`, even if `"a"` or `"a/b"` is in `revealed`, `mergedChild` still merges `a/b/c` and hides all revealed files in `a` and `a/b`.
  - **Reproduction output from `DocumentAuditBench` (`[Test E1]` & `[Test E2]`)**:
    ```text
    [Test E1 - FileTree folded: 'a/readme.md' and 'a/b/notes.txt' vanish with NO .unchanged row]
      kind=folder name='a/b/c' path='a/b/c' changed=1
        kind=file name='changed.swift' path='a/b/c/changed.swift' changed=1
    [Test E2 - FileTree with revealed=['a/b']: 'a/b' still merges into 'a/b/c' and ignores revealed]
      kind=folder name='a/b/c' path='a/b/c' changed=1
        kind=file name='changed.swift' path='a/b/c/changed.swift' changed=1
    ```
- **Fix**:
  In `Folder.mergedChild` (`FileTree.swift:102`), only merge a folder with its single child folder when `!revealed.contains(path)` and either the folder has no hidden unchanged items of its own (`files.isEmpty && folders.count == 1`) or the merged row's `.unchanged` count includes/reveals the intermediate folders' unchanged items.

---

### Finding 7 (Bug — Medium-High Impact): `FileState.reference` silently drops deleted lines whenever a selection includes a context line, and `FileState.lineNumber(at:)` crashes when `lines` is empty
- **Location**: `Sources/SextantApp/Document.swift:80-97`, `Sources/SextantApp/WindowActions.swift:359`
- **Category**: Bug
- **Plan Step**: Step 1 (Confirmed bugs)
- **Evidence**:
  1. **`FileState.reference(_ indices: [Int])` (`Document.swift:89-97`)**:
     ```swift
     let old = picked.allSatisfy { lines[$0].kind == .deleted }
     let kept = old ? picked : picked.filter { lines[$0].kind != .deleted }
     ```
     If a user in Side-by-Side mode selects lines in the left (old-side) column that span 1 context line and 2 deleted lines (or in Unified mode selects a context line + deleted lines) and presses `C` (Add Note) or `Copy Reference`:
     - `picked.allSatisfy { lines[$0].kind == .deleted }` is `false` because of the context line.
     - `kept` filters out `lines[$0].kind == .deleted`, **dropping all the deleted lines the user selected**, keeping only the context line, and anchoring the note to the new side (`old = false`)! (Verified in `DocumentAuditBench [Test F1]`: selecting indices `[0, 1, 2]` returns `ref.old=false, ref.lines=1...1, ref.code=["ctx 1"]`).
  2. **`FileState.lineNumber(at i: Int)` (`Document.swift:80-83`)**:
     ```swift
     func lineNumber(at i: Int) -> (number: Int, old: Bool) {
         let l = lines[min(max(0, i), lines.count - 1)]
         return l.kind == .deleted ? (l.oldNo, true) : (l.newNo, false)
     }
     ```
     When `lines` is empty, `lines.count - 1` is `-1`, and `lines[-1]` traps with `Fatal error: Index out of range`. `WindowActions.readerMenu` (`WindowActions.swift:359`) calls `f.lineNumber(at: $0)` without a `!f.lines.isEmpty` guard.
- **Fix**:
  1. Pass the active column's side (`old: Bool?`, or check ` !picked.contains { lines[$0].kind == .added } && picked.contains { lines[$0].kind == .deleted }`) into `reference(_:)` so selecting deleted + context lines (with no added lines) references the old side (`old = true`) and keeps both `.context` and `.deleted` lines.
  2. Guard `guard !lines.isEmpty else { return (1, false) }` in `FileState.lineNumber(at:)`.

---

### Finding 8 (Bug — Medium-High Impact): Toggling `showAll` off (`toggleShowAll`) while `topPosition` is on an unchanged line immediately unfolds the newly created fold and clobbers the caret selection
- **Location**: `Sources/SextantApp/Reader.swift:281-308`, `Reader.swift:698-709`, `Sources/SextantApp/WindowActions.swift:505-508`
- **Category**: Bug
- **Plan Step**: Step 1 (Confirmed bugs) & Step 3 (Cheap UI fast paths)
- **Evidence**:
  Trace `WindowActions.toggleShowAll` (`WindowActions.swift:505-508`) when the user switches `reader.showAll` from `true` (all lines visible) to `false` (fold unchanged lines) while looking at an unchanged region of a file (say line 50 inside `0..<200`):
  1. `Reader.reload(keepPosition: true)` (`Reader.swift:282`) saves `let pos = keepPosition ? topPosition : nil` (`pos.line == 50`) and `let kept = keepPosition ? keptSelection : nil`.
  2. `layoutRows(..., showAll: false, ...)` folds lines `0..<200` into `.fold(0..<200)`.
  3. At line 304, `reload(keepPosition: true)` calls `if let pos { scroll(to: pos, animated: false, offset: topOffset) }`.
  4. `scroll(to: pos)` calls `row(for: pos, in: primary)` (`Reader.swift:698-709`):
     ```swift
     if let fold = rows.firstIndex(where: { r in
         if case .fold(let range) = r.kind { return r.file == p.file && range.contains(p.line) }
         return false
     }), case .fold(let range) = rows[fold].kind {
         files[p.file].unfolded.insert(range.lowerBound)
         reload(keepPosition: false)
         return code.rows.firstIndex { $0.file == p.file && $0.kind == .line && $0.line == p.line }
     }
     ```
  5. `row(for: pos, in: primary)` sees that `pos.line` (`50`) is inside `.fold(0..<200)`, so it **inserts `0` into `files[0].unfolded` and recursively calls `reload(keepPosition: false)`**!
  6. This both **undoes the fold** the user just asked for and runs `reload(keepPosition: false)` which sets `kept = nil` and resets the selection to `NSRange(location: 0, length: 0)`!
- **Fix**:
  1. In `toggleShowAll`, clear `files.forEach { $0.unfolded.removeAll() }` when folding (`!reader.showAll`).
  2. Separate pure row lookup (`row(for:in:unfolding: Bool)`) from unfolding: `reload(keepPosition: true)` restoring `topPosition` should pass `unfolding: false` (mapping a folded `topPosition` to the `.fold` row itself), while explicit navigation (`land(onLine:)`, `goToDefinition`, `placeCaret`) passes `unfolding: true`.

---

### Finding 9 (Slowness & Concurrency Bug — High Impact): `prepareWhole(git:analyzing: true)` from `prepareNeighbors` couples blob loading with two-sided tree-sitter parsing, blocking `open()` from showing a file until background syntax analysis finishes
- **Location**: `Sources/SextantApp/Document.swift:140-155`, `Sources/SextantApp/RepoWindowController.swift:527-534, 543-553`
- **Category**: Slowness / Concurrency
- **Plan Step**: Step 2 (Limits and lifetimes)
- **Evidence**:
  In `FileState.prepareWhole(git:analyzing:)` (`Document.swift:140-155`):
  ```swift
  func prepareWhole(git: Git, analyzing: Bool) async {
      guard !hasWhole, !diff.isBinary else { return }
      if let wholeLoad { return await wholeLoad.value }
      let diff = self.diff, isChange = self.isChange, contentAnalysis = self.contentAnalysis
      let task = Task {
          guard let old = try? await git.oldLines(of: diff) else { return }
          let all = await Task.detached(priority: .userInitiated) { wholeFile(diff.hunks, oldLines: old) }.value
          let analysis = analyzing
              ? await FileState.analyze(all, path: diff.path, isChange: isChange, symbols: true, blobs: FileState.blobs(of: diff.change), contentAnalysis: contentAnalysis)
              : nil
          preparedWhole = (all, analysis)
      }
      wholeLoad = task
      await task.value
      wholeLoad = nil
  }
  ```
  When the user opens file $i$, `prepareNeighbors` (`RepoWindowController.swift:543-553`) immediately starts `prepareWhole(git: git, analyzing: true)` on files $i+1, i-1, i+2$.
  Inside `wholeLoad`, `preparedWhole` is not set until **after** `FileState.analyze` finishes parsing both old and new blobs with tree-sitter.
  When the user steps to file $i+1$ (`open`), `f.hasWhole` is still `false`, so `fileState` calls `await f.prepareWhole(git: git, analyzing: false)`.
  Line 142 (`if let wholeLoad { return await wholeLoad.value }`) suspends `open()` until `prepareNeighbors`'s full two-sided tree-sitter parse finishes — directly contradicting the design that a file about to show renders its text immediately and analyzes after showing.
  Furthermore, when multiple panes share a `Session` (`RepoWindowController.swift:283`), calling `f.adoptWhole()` in one pane mutates `f.lines` in-place while another pane showing Overview still holds hunk-relative line indices in `CodeView.rows`.
- **Fix**:
  1. Have `prepareWhole` only load `oldLines` and compute `wholeFile` (setting `preparedWholeLines = all` immediately after `wholeFile`), and run `analyze(symbols: true)` as a separate, cancellable task.
  2. Never mutate `f.lines` in-place while an Overview pane is displaying hunk-only `Row`s for `f`, or have `Row` reference stable line storage.

---

### Finding 10 (Waste & Slowness — High Impact): `reviewsChanged` calls `refreshReadState()` (looping `recolor(file:)` + `colorVisibleRows()` $N_{\text{files}}$ times) and then calls `reader.reload(keepPosition: true)` in Overview even though `layoutRows` and `render` do not depend on `reviewed` or `read`
- **Location**: `Sources/SextantApp/RepoWindowController.swift:769-780`, `Sources/SextantApp/Reader.swift:321-327`, `Sources/SextantApp/CodeView.swift:292-297`
- **Category**: Waste / Slowness
- **Plan Step**: Step 3 (Cheap UI fast paths)
- **Evidence**:
  In `RepoWindowController.reviewsChanged(_:)` (`RepoWindowController.swift:769-780`):
  ```swift
  for p in panes {
      p.reader.refreshReadState()
      if case .overview? = p.focus { p.reader.reload(keepPosition: true) } else { p.reader.updateHeader() }
  }
  ```
  1. `p.reader.refreshReadState()` (`Reader.swift:321-327`) executes:
     ```swift
     for c in columns {
         for i in files.indices { c.code.recolor(file: i) }
     ```
     In Overview with 5,000 files, `c.code.recolor(file: i)` (`CodeView.swift:292-297`) runs 5,000 times per column, and **every single call** invokes `colorVisibleRows()` (which queries `layoutManager.glyphRange(forBoundingRect:in:)` 5,000 times!).
  2. Immediately after `refreshReadState()` finishes, line 776 calls `p.reader.reload(keepPosition: true)` when `p.focus` is `.overview` — which rebuilds `layoutRows`, rebuilds the entire `NSMutableAttributedString` via `render(...)`, replaces `textStorage`, and resets `colored = []`!
  3. Yet neither `layoutRows` (`Document.swift:448-510`) nor `render` (`CodeView.swift:81-137`) reads `f.reviewed` or `isReadLine`! Read/unread colors are applied solely as `NSLayoutManager` temporary attributes in `CodeView.color(row:_:)`, and line backgrounds are drawn dynamically in `CodeView.drawBackground(in:)`, while `f.reviewed` is only shown in `PaneHeader.update`.
- **Fix**:
  1. In `reviewsChanged`, never call `p.reader.reload(keepPosition: true)` for `.overview`; call `p.reader.updateHeader()` just like single-file mode.
  2. In `Reader.refreshReadState()`, replace `for i in files.indices { c.code.recolor(file: i) }` with a single `c.code.recolorAll()` that does `colored.removeAll(); colorVisibleRows()` once per column.

---

### Finding 11 (Slowness & Waste — High Impact): `fileTree` splits, hashes, walks, and `localizedStandardCompare`-sorts all $N$ snapshot paths on every rebuild (296 ms at 300k paths), and sorts all unchanged files in every visited folder before filtering `isChanged`
- **Location**: `Sources/SextantCore/FileTree.swift:34-96`, `Sources/SextantApp/Navigator.swift:426-441`
- **Category**: Slowness / Waste (Refines known Navigator rebuild finding with internal `FileTree.swift` root causes)
- **Plan Step**: Step 3 (Persistent navigator nodes)
- **Evidence**:
  Inside `fileTree` (`FileTree.swift:34-96`):
  1. Lines 36-37 split every path in `paths` (`p.split(separator: "/").map(String.init)[...]`), allocating $2N$ arrays and $N \times \text{depth}$ strings on every call (`setFiles`, `refreshReviewState`, `modeChanged`, `reveal`, `itemCollapsed`).
  2. Line 38 (`root.count(prefix: "", changed: changed, reviewed: reviewed)`) recursively walks **all $N$ files in the snapshot**, concatenating `let p = prefix + name` ($N$ string allocations) and probing `changed.contains(p)` just to count `changed` and `reviewed` — even when `changed` has only 10 files out of 300,000!
  3. Lines 81-89 (`Folder.nodes`) call `Folder.sorted(folders.keys)` and `Folder.sorted(files)` (using `localizedStandardCompare`) on **all** subfolders and **all** files in every visited folder *before* checking `guard showsEverything || f.changed > 0` / `guard showsEverything || isChanged`! In a folder with 5,000 unchanged files and 1 changed file, all 5,000 unchanged filenames are sorted with `localizedStandardCompare` and 4,999 are immediately discarded.
  4. Line 92 recomputes `hidden` by allocating two filtered arrays and re-concatenating `prefix + $0` for every file in the folder.
  - **Benchmark (`DocumentAuditBench [Bench 1]`, 10 changed files, `showUnchanged = false`)**:
    - `1,000` paths: **1.05 ms**
    - `10,000` paths: **9.47 ms**
    - `100,000` paths: **98.18 ms**
    - `300,000` paths: **296.11 ms**
- **Fix**:
  1. Filter `folders` and `files` by `showsEverything || f.changed > 0` / `showsEverything || isChanged` **before** sorting with `Folder.sorted`, and compute `hidden` by subtracting shown counts from `folders.count + files.count`.
  2. Compute `changed` and `reviewed` counts by walking `changed` ($O(|\text{changed}| \times \text{depth})$) rather than walking all $N$ snapshot files in `root.count`.
  3. Build the parsed snapshot folder tree once per `snapshotFiles` load (off the main thread, pre-sorted), and on `refreshReviewState` update only the `changed`/`reviewed` counters along the ancestor chains of changed files and call `outline.reloadItem`.

---

### Finding 12 (Bug & Slowness — Medium-High Impact): `identifiers(in:tokens:)`, `wholeWordMatches`, and `CodeView.identifier(at:)` fail on non-BMP Unicode scalars (surrogate pairs) and run $O(L_{\text{utf16}} + I \times T_{\text{skipped}})$ on every line of both sides during `indexNames()`
- **Location**: `Sources/SextantCore/Reading.swift:3-31, 56-70`, `Sources/SextantCore/Names.swift:175-187`, `Sources/SextantApp/CodeView.swift:1020-1033`
- **Category**: Bug & Slowness (Refines known `identifiers(in:tokens:)` finding with surrogate-pair bug and `NameIndex.candidates` call site)
- **Plan Step**: Step 1 (Confirmed bugs) & Step 6 (Content)
- **Evidence**:
  1. **UTF-16 surrogate pair bug (`Reading.swift:3-6`, `CodeView.swift:1022-1025`)**:
     ```swift
     private func isIdentifierUnit(_ u: unichar) -> Bool {
         guard let s = UnicodeScalar(u) else { return false }
         return CharacterSet.alphanumerics.contains(s) || s == "_" || s == "$"
     }
     ```
     `nsString.character(at: i)` returns a single 16-bit UTF-16 code unit (`unichar`). For any non-BMP character (U+10000..U+10FFFF, encoded as a high surrogate `0xD800..0xDBFF` and low surrogate `0xDC00..0xDFFF`), `UnicodeScalar(u)` returns `nil`.
     - `identifiers(in: "let 𝕏 = 42", tokens: [])` drops `"𝕏"` completely (`DocumentAuditBench [Test G]`).
     - `wholeWordMatches(of: "foo", in: "𝕏foo")` sees `isIdentifierUnit` return `false` on the low surrogate of `𝕏` at `r.location - 1`, so it **falsely matches `"foo"` as a whole word inside `"𝕏foo"`** (`DocumentAuditBench [Test G]`: returns `[{2, 3}]`).
  2. **Hidden whole-file call site in `NameIndex.candidates(in:tokens:)` (`Names.swift:179`)**:
     `identifiers(in:tokens:)` is not only called for the caret line in `CodeView`; `FileState.indexNames` calls `NameIndex.candidates(in:tokens:)`, which calls `identifiers(in:tokens:)` on **every line of both the old and new sides of the entire file**!
  3. **Benchmark (`DocumentAuditBench [Bench 2]`)**:
     Replacing `UnicodeScalar(u)` + `CharacterSet.alphanumerics` and the $O(I \times T)$ `skipped.contains` scan with a fast ASCII check + two-pointer scan over sorted `skipped` tokens speeds up `identifiers(in:tokens:)`:
     - `1,430` chars / `150` tokens: **0.10 ms -> 0.003 ms (28.6x faster)**
     - `15,280` chars / `1,500` tokens: **2.19 ms -> 0.029 ms (74.6x faster)**
     - `80,280` chars / `7,500` tokens: **43.71 ms -> 0.145 ms (301.4x faster)**
- **Fix**:
  Use a fast ASCII lookup table for `u < 128`, decode surrogate pairs (`0xD800..0xDBFF` + `0xDC00..0xDFFF`) into full 21-bit `UnicodeScalar`s before checking `UnicodeScalar.Properties.isAlphabetic`/`isIdeographic`/`numericType`, and advance a single index through `skipped` tokens in $O(I + T)$ instead of $O(I \times T)$.

---

### Finding 13 (Waste & Slowness — Medium Impact): `layoutRows` scans all `notes` per file and all `lines` per note ($O(F \times N_{\text{notes}} \times L)$), allocates an unused `right: [Row]` in Unified mode, and only checks `on.code.last` when anchoring multi-line notes
- **Location**: `Sources/SextantApp/Document.swift:423-428, 448-510`
- **Category**: Waste / Slowness / Bug
- **Plan Step**: Step 3 (Cheap UI fast paths)
- **Evidence**:
  1. In `layoutRows` (`Document.swift:450-460`):
     - `func both(_ r: Row) { left.append(r); right.append(r) }` appends every header, notice, fold, gap, and note to `right` even when `sideBySide == false`, discarding `right` at line 509.
     - `for n in notes { if let a = f.anchor(of: n) { ... } }` iterates over every note in the review for every file in `files`, and inside `f.anchor(of: n)` (`Document.swift:425`) runs a linear `lines.firstIndex` scan ($O(L)$) over `f.lines`.
     - **Benchmark (`DocumentAuditBench [Bench 3]` & `[Bench 4]`)**: Pre-grouping `notes` by `path`, binary-searching `f.lines` by line number, and skipping `right.append` when `!sideBySide` reduces `layoutRows` from **11.90 ms to 4.45 ms (2.7x faster)** on 5,000 files with 100 notes, and from **0.68 ms to 0.07 ms (9.4x faster)** on a single 50,000-line file with 50 notes.
  2. In `FileState.anchor(of:)` (`Document.swift:426`):
     `return on.code.last.map { $0 == lines[i].text } ?? true ? i : nil`
     Only the **last** line of `on.code` is compared! If a note was written on a 5-line block ending with `"}"` and the first 4 lines were deleted or rewritten while `"}"` remains at that line number, the note stays anchored to unrelated code.
  3. In `FileState.folds(keeping:)` (`Document.swift:417-421`):
     `!anchored.contains { r.contains($0) }` drops the **entire** unchanged fold range `r` (even if `r` is 10,000 lines long!) whenever a single note is anchored anywhere inside `r`, instead of splitting `r` around the anchored line with 3 lines of context.
- **Fix**:
  1. Pre-group `notes` by `lines.path` once at the start of `layoutRows`, binary-search `f.lines` in `anchor(of:)`, and guard `if sideBySide { right.append(r) }` in `both`.
  2. In `anchor(of:)`, verify that all lines of `on.code` match the side's lines ending at `i` (or split `foldedRuns` around anchored lines with `context: 3`).

---

### Finding 14 (Waste — Medium Impact): `RawChange.reviewKey` allocates a new heap `String` on every access (including every changed line during `CodeView.color` and every `drawBackground` paint frame), and `FileState.run(at:)` linearly scans `keyedRuns`
- **Location**: `Sources/SextantCore/Model.swift:31`, `Sources/SextantApp/Document.swift:353-361`, `Sources/SextantApp/Reader.swift:296`, `Sources/SextantApp/CodeView.swift:338, 691`
- **Category**: Waste
- **Plan Step**: Step 3 (Cheap UI fast paths)
- **Evidence**:
  `Reader.reload` (`Reader.swift:296`) sets:
  ```swift
  c.code.isReadLine = { fi, li in files[fi].run(at: li).map { isRead(files[fi], $0) } ?? false }
  ```
  where `isRead` (`RepoWindowController.swift:122`) calls `repository?.reviews.isRead(run.key, in: f.diff.change)` -> `state.isRead(change, in: c.reviewKey)`.
  1. `f.run(at: li)` (`Document.swift:361`) does `keyedRuns.first { $0.run.lines.contains(line) }`, a linear scan over `keyedRuns` even though `keyedRuns` are strictly sorted by disjoint `Range<Int>`.
  2. `c.reviewKey` (`Model.swift:31`) is a computed property `"\(oldOid) \(oldMode) \(newOid) \(newMode)\t\(oldPath)\t\(path)"` that allocates a ~110-byte heap `String` on every call — on every changed line in `CodeView.color(row:_:)` AND on every visible changed line in `CodeView.drawBackground(in:)` on every frame, plus in `ReviewStore.progress` for every file in every commit row.
  - **Benchmark (`DocumentAuditBench [Bench 7]`, 2,000 changed lines)**:
    Replacing linear `run(at:)` + computed `reviewKey` with binary search + stored `reviewKey` reduces lookup time from **1.11 ms to 0.209 ms (5.3x faster)** with zero heap allocations.
- **Fix**:
  Precompute `let reviewKey: String` on `RawChange` (or `FileState`) and use binary search in `FileState.run(at:)`.

---

### Finding 15 (Waste & Unbounded Growth — Medium Impact): `ReviewStore.update` rewrites both `reviewed.json` and `read.json` on the main thread even when only one changed, and neither `ReviewStore` nor `NotesStore` bounds historical keys or evicts closed repositories
- **Location**: `Sources/SextantApp/ReviewStore.swift:11-67`, `Sources/SextantCore/Reading.swift:159-165`, `Sources/SextantApp/Notes.swift:51-116`, `Sources/SextantApp/WindowActions.swift:380-384`
- **Category**: Waste / Architecture
- **Plan Step**: Step 3 (Review/notes persistence off main)
- **Evidence**:
  1. In `ReviewStore.update` (`ReviewStore.swift:50-58`):
     ```swift
     save(s.reviewed, to: reviewedURL)
     save(s.read, to: readURL)
     ```
     Marking a single hunk read only mutates `s.read`, yet `update` sorts, pretty-prints, and atomically writes **both** `reviewed.json` and `read.json` on the main thread (and vice versa when marking a file reviewed with no read hunks).
  2. `ReviewStore.state.reviewed` and `ReviewStore.state.read` never prune old blob-transition keys; at 50,000 accumulated keys across a repo's history, `setReviewed` + sorting/encoding both JSONs takes **96.53 ms** on the main thread (`DocumentAuditBench [Bench 6]`: `40.00 ms` in `setReviewed` prefix filtering + `56.53 ms` in `sorted()` + `JSONEncoder`).
  3. `Notes.markdown(_:)` (`Notes.swift:57`) and `WindowActions.copyReferenceWithCode` (`WindowActions.swift:381`) call `SyntaxRuntime.shared?.language(forPath: path)?.name` on the main thread, which calls `load(e)` (`dlopen` + SHA-256 + compiling `highlights.scm`, `tags.scm`, `locals.scm`) just to get the language's name string for a Markdown fence, and hardcodes ```` ``` ```` fences (which break if `l.code` contains ```` ``` ````).
- **Fix**:
  1. In `ReadingState`, store `read: [String: Set<UInt64>]` keyed by file `reviewKey` so `setReviewed` removes `read[file]` in $O(1)$ instead of $O(|R_{\text{read}}| \times |F|)$ prefix scanning.
  2. In `ReviewStore.update`, compare `s.reviewed != old.reviewed` and `s.read != old.read` so only the changed set is serialized, and coalesce writes off the main actor.
  3. Add a non-loading `SyntaxRuntime.languageName(forPath:)` that returns `entry(forPath: path)?.name` without calling `load(e)`, and use a backtick fence longer than any backtick run in `l.code`.

---

### Finding 16 (Waste — Medium Impact): Opening a modified file and resting the caret on an identifier runs up to 6 tree-sitter parses of the file across `analyze(symbols: false)`, `analyze(symbols: true)`, and `indexNames()`
- **Location**: `Sources/SextantApp/Document.swift:175-188, 208-238, 267-291`, `Sources/SextantCore/ContentAnalysis.swift:52-66`, `Sources/SextantCore/Names.swift:262-277`
- **Category**: Waste (Refines known analysis findings with exact `Document.swift` -> `ContentAnalysis` -> `Names` trace)
- **Plan Step**: Step 6 (Content)
- **Evidence**:
  1. When a file is shown in Overview (`Reader.analyzeShownFiles`, `Reader.swift:235`), `f.analyze(symbols: false)` runs:
     - If `f` is an added/deleted whole blob (`sidesAreBlobs == true`), `ContentAnalysis.analysis(of:..., definitions: false)` parses the blob and caches `BlobAnalysis(tokens: ..., definitions: nil)` in `recent`.
     - If `f` is a modified file (`sidesAreBlobs == false`), it parses both sides of the hunk lines directly via `language.analysis(of: text, definitions: false)`.
  2. When the user opens `f` in single-file mode, `f.analyze(symbols: true)` runs:
     - Even for an added/deleted file that was **just parsed** in Overview, `ContentAnalysis.analysis(of:..., definitions: true)` (`ContentAnalysis.swift:55`) sees `hit.definitions == nil`, discards the cached token parse, and **parses + highlights the entire blob a second time**!
  3. When the caret rests on a name for 100 ms (`Reader.updateOccurrences` -> `f.indexNames()`, `Document.swift:267-291`), `indexNames` calls `language.names(of:tokens:)` (`Names.swift:262-277`) **serially** on the new side and then the old side:
     - Each side re-joins the lines and **parses the entire file a third time with tree-sitter** to run `localsQuery`, and calls `root.descendant(in:)` + `node.nodeType` for every candidate identifier in the file.
     - Furthermore, in `FileState.occurrences(atLine:column:)` (`Document.swift:316-325`), cross-side local variable matching requires the local variable itself to appear on at least one `.context` line (`guard self.lines[l].kind == .context`), so any local variable whose entire declaration and uses were modified in a hunk fails to match its old-side counterpart even when the enclosing function scope is on a `.context` line.
- **Fix**:
  In Step 6, parse each blob once in `ContentAnalysis` to produce tokens, `Symbol` definitions, and `LocalCaptures` (or `NameIndex`) in a single cursor walk, and run old/new side name indexing in parallel (`async let`).

---

### Finding 17 (Bug — Low-Medium Impact): `jumpLabels(_ count: Int)` silently truncates at 676 labels (`26 * 26`), and `Reader.jumpTargets` searches off-screen horizontal text of visible rows
- **Location**: `Sources/SextantCore/Reading.swift:85-106`, `Sources/SextantApp/Reader.swift:552-561`, `Sources/SextantApp/CodeView.swift:643-664`
- **Category**: Bug & Waste
- **Plan Step**: Step 1 & Step 3
- **Evidence**:
  1. `jumpLabels(_ count: Int)` (`Reading.swift:102-106`) generates at most $26 \times 26 = 676$ two-letter labels (`DocumentAuditBench [Test G]`: `jumpLabels(1000).count == 676`). When a common 2-char query (like `"  "` on indented code) has $> 676$ matches in the visible rows, matches beyond 676 get no label.
  2. `Reader.jumpTargets(_ query: String)` (`Reader.swift:552-561`) searches the entire `charRange(ofRow:)` of each visible row rather than the horizontally visible character range (`glyphRange(forBoundingRect: visibleRect, in: tc)`). On long unwrapped lines, matches off-screen to the right inflate `targets.count` (forcing 2-key label picking when only 1 match is actually on screen, or entering `.picking` mode with 0 visible labels on screen when all matches are off-screen to the right) and cause `CodeView.draw` (`CodeView.swift:651`) to call `lm.boundingRect` for every off-screen match.
- **Fix**:
  Restrict `Reader.jumpTargets` to the character range of `visibleRect` in each visible line fragment, and extend `jumpLabels` (or cap `jumpTargets` to visible on-screen matches).

---

### Finding 18 (Bug — Low-Medium Impact): `FileState.isTwoSided` returns `false` for modified files that only add or only delete lines, unexpectedly collapsing Side-by-Side view to 1 column when stepping between files
- **Location**: `Sources/SextantApp/Document.swift:98-102, 450`
- **Category**: Bug / UX Inconsistency
- **Plan Step**: Step 3
- **Evidence**:
  In `Document.swift:98-102`:
  ```swift
  var hasOldSide: Bool { lines.contains { $0.kind == .deleted } }
  var hasNewSide: Bool { lines.contains { $0.kind == .added } }
  /// Whether both sides have content, so side-by-side shows something on each.
  var isTwoSided: Bool { hasOldSide && hasNewSide }
  ```
  For a modified existing file (`!diff.change.isAdded && !diff.change.isDeleted`) whose change only adds lines (`diff.deletions == 0`) or only removes lines (`diff.additions == 0`), both the old file and the new file have content (`.context` lines exist on both sides!), yet `isTwoSided` returns `false`.
  In Overview mode (`overview == true`), `layoutRows` (`Document.swift:450`) shows the file in 2 columns, but when the user opens that same file in single-file mode with Side-by-Side (`split == true`) enabled, `sideBySide` becomes `false` and the reader collapses to 1 column (and also scans `lines.contains` linearly instead of checking `diff`).
- **Fix**:
  Define `isTwoSided` as `isChange && !diff.change.isAdded && !diff.change.isDeleted && !lines.isEmpty` (or check `diff.deletions > 0 || diff.additions > 0` on modified files) without scanning `lines`.

---

## 4. Correctness Edge Cases That a Performance Rewrite Could Break

When implementing Steps 1, 2, 3, 6, and 8 of `scratch/perf/plan.md`, the following invariants and edge cases in this scope must be preserved (or explicitly fixed as above):

1. **Line-number monotonicity with `0` sentinels (`DiffLine.oldNo` / `newNo`)**:
   - Any binary search replacing `lines.firstIndex` in `FileState.index(ofLine:old:)`, `FileState.anchor(of:)`, or `Reader.stepChangedDefinition` **must account for `oldNo == 0` on `.added` lines and `newNo == 0` on `.deleted` lines** (either by populating monotonic 1-based positions on both fields or skipping `0` entries during binary search). Naive binary search on `l.newNo` will partition in the wrong direction whenever `mid` lands on a `.deleted` line (`newNo == 0`).
2. **Hunk-boundary gaps (`gapsBefore`) vs whole-file folds (`folds`)**:
   - In `layoutRows` (`Document.swift:481, 490`), a `.gap` row can appear at the exact start of a `.deleted`/`.added` run (`i == runStart`), whereas a `.gap` at `i != runStart` splits two adjacent hunks' change runs so they don't merge across an unloaded gap. Any lazy blob-loading or per-block overview edit (Step 8) must preserve `gapsBefore` semantics until a file's whole blob is adopted.
3. **Unfolding a fold or gap in Overview vs Single-File mode (`CodeView.swift:109-114`, `Reader.swift:902-907`)**:
   - Clicking a `.fold(r)` pill dispatches `.unfold(file: row.file, at: r.lowerBound)`, whereas clicking a `.gap(hidden)` pill dispatches `.openFile(file: row.file, line: row.line)` (which branches a new pane in Overview at `f.lineNumber(at: line)`). If Overview lazily loads whole blobs only when unfolded (Step 2/3), clicking `.gap` in Overview must still know the target line number before or after whole-blob adoption.
4. **Reading the last unread `ChangeRun` auto-reviews the file, and unreading a `ChangeRun` in a reviewed file restores all other runs as read (`Reading.swift:148-156`)**:
   - `ReadingState.setRead` has a two-way invariant:
     - When `value == true` and `all.allSatisfy(read.contains)` (with `!all.isEmpty`), the file's `reviewKey` is inserted into `reviewed` and all its per-run keys are cleared from `read`.
     - When `value == false` on a file that is currently in `reviewed`, `reviewed.remove(file)` must populate `read.formUnion(all)` before removing `change`, so all *other* runs in the file remain read.
   - Replacing `read: Set<String>` with a per-file dictionary or SQLite/off-main persistence (Step 3) must preserve this exact transition.
5. **Keeping selection and scroll anchor across `reload(keepPosition: true)` (`Reader.swift:281-314, 581-602, 667-686`)**:
   - `KeptSelection` and `topAnchor` record `(file, line)` where `line` is an **index into `f.lines`**, NOT a 1-based git line number!
   - If `f.adoptWhole()` / `f.setWhole()` replaces `f.lines` (changing `f.lines` from hunk-only to whole-file), indices into `f.lines` shift by the number of unchanged lines filled in before each hunk. Any code path that transitions `f` from hunk-only to whole-file must translate the viewport top and caret via `f.lineNumber(at:)` -> `f.index(ofLine:old:)` (as `RepoWindowController.currentLocation` does), never via raw `ReaderPosition.line` indices.
6. **Last row in `CodeView.render` omits trailing `\n` (`CodeView.swift:131`)**:
   - `if ri < rows.count - 1 { plain += "\n" }` omits the newline on the last row so TextKit does not create an extra trailing line fragment. `CodeView.charRange(ofRow: r)` (`CodeView.swift:387-391`) relies on `r + 1 < rowStarts.count ? rowStarts[r + 1] - 1 : textStorage.length`. Any incremental per-block text replacement in Step 8 must preserve this invariant at the end of `NSTextStorage`.
