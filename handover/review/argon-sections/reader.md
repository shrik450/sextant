# Scoped Architecture & Efficiency Audit: Reader & Text Rendering (`Reader.swift`, `CodeView.swift`)

Scope: `Sources/SextantApp/Reader.swift` and `Sources/SextantApp/CodeView.swift` (with call-following into `Sources/SextantApp/Document.swift`, `Sources/SextantApp/PaneHeader.swift`, `Sources/SextantApp/RepoWindowController.swift`, `Sources/SextantApp/WindowActions.swift`, `Sources/SextantApp/Theme.swift`, and `Sources/SextantCore/Reading.swift`).

To reproduce all microbenchmarks and adversarial verification tests in this report:
```sh
cd /Users/shrik450/Developer/review-ui/scratch/review/argon-sections/reader
nix develop /Users/shrik450/Developer/review-ui -c swift build -c release
./.build/release/ReaderAuditBench
```

---

## 1. Architecture Overview & Target Design Fit

### Ownership and Data Flow
- **`Reader` (`Reader.swift:29`)**: Owns the pane's `PaneHeader`, `ChangeCounter`, `EmptyState`, horizontal `NSStackView` of 1 or 2 `Column`s (`GutterScrollView` + `CodeView` + `Gutter`), the `Layout` (`left: [Row]`, `right: [Row]?`), `changeStops: [Int]`, active occurrence state (`boxed`, `pendingOccurrences`), `usesWord`, `jump` state + `JumpPrompt`, and the background `analysis: Task<Void, Never>?` loop.
  - **Inputs**: `files: [FileState]`, `overview: Bool`, `notes: [Note]`, `split: Bool`, `showAll: Bool`, `wraps: Bool`, `blame: Blame?`, and `isRead: (FileState, FileState.KeyedRun) -> Bool`.
  - **Outputs**: `ReaderDelegate` callbacks to `RepoWindowController` (`readerFocused`, `readerOpenFile`, `readerUnfolded`, `readerJumpToDefinition`, `readerEditNote`, `readerMenu`, `readerCurrentFileChanged`, `readerBlameClicked`, `readerCaretMoved`, `readerAddNote`, `readerPeek`).
- **`render(_:side:files:notes:style:)` (`CodeView.swift:84`)**: Pure-ish builder on `@MainActor` taking `[Row]` and `[FileState]` and producing `RenderedText(string: NSAttributedString, rowStarts: [Int])`.
- **`CodeView` (`CodeView.swift:172`)**: Subclass of `NSTextView` (TextKit 1: `NSTextStorage` + `NSLayoutManager` + `NSTextContainer`). Owns `rows: [Row]`, `rowStarts: [Int]`, `files: [FileState]`, `colored: IndexSet`, `occurrences: [RowRange]`, `lineRows: [Int: [Int32]]`, `uses: [NSRange]`, `jumpLabels`, and selection/navigation state (`anchorIndex`, `headIndex`, `goalColumn`, `lineSelectionStart`, `hoveredPill`).
- **`Gutter` (`CodeView.swift:1166`)**: Subclass of `NSRulerView` paired with `CodeView` inside `GutterScrollView`. Draws line numbers, diff status bands/bars, blame commit labels, and the `+` note badge; handles gutter click/drag line selection.

### What Is in the Wrong Place or Duplicated
1. **Per-row `.sextantAction` attributes in `NSAttributedString` duplicate `CodeView.rows[r]` (`CodeView.swift:107-128, 593-597`)**:
   `render()` allocates a unique `[NSAttributedString.Key: Any]` dictionary (and for headers, a new `NSMutableParagraphStyle`) for every `.fold`, `.gap`, `.header`, and `.note` row solely to attach `.sextantAction: ReaderAction`. Yet `CodeView.mouseDown` (`CodeView.swift:593-597`) already maps the clicked character index `ci` to `r = row(at: ci)` and inspects `rows[r]`. `rows[r]` already encodes the exact `ReaderAction` (`.fold(let range)`, `.gap`, `.header`, `.note(let id)`). Eliminating `.sextantAction` from `NSAttributedString` collapses thousands of unique attribute dictionaries down to 4 shared static dictionary instances per `render()`.
2. **Lookup method `Reader.row(for:in:)` mutates model state and recursively triggers `reload(keepPosition: false)` (`Reader.swift:491-502`)**:
   `row(for:in:)` is called as a coordinate query by `scroll(to:)`, `placeCaret(at:)`, `land(onLine:)`, and `stepDefinition`. When `p.line` lies inside a `.fold(let range)`, `row(for:in:)` mutates `files[p.file].unfolded` and calls `reload(keepPosition: false)` from inside the lookup. When called from `reload(keepPosition: true)` (e.g. during `toggleShowAll`), this causes a recursive `reload(keepPosition: false)` mid-reload.
3. **`Reader` repeatedly scans `code.rows` linearly in O(R) while `CodeView` owns the binary-search primitives (`Reader.swift:309, 432, 442, 450, 491-502, 661` vs `CodeView.swift:195-204, 370-376`)**:
   `CodeView` has `rowRange(ofFile:)` (O(log R) binary search) and `rows(ofLinesIn:)` (cached `[Int32]` line-to-row table), both `private`. Meanwhile `Reader` performs linear `code.rows.firstIndex(where:)` and `code.rows.indices.filter` scans across up to hundreds of thousands of rows.
4. **Per-line read-state resolution lives inside the hot draw/color loops (`Reader.swift:256`, `CodeView.swift:227, 515, 1265`)**:
   `c.code.isReadLine` runs during `color(row:)`, `CodeView.drawBackground`, and `Gutter.drawHashMarksAndLabels` for every visible changed line. Each call linearly scans `files[fi].keyedRuns`, copies a `KeyedRun`, and interpolates `RawChange.reviewKey` (`"\(oldOid) ..."`).
5. **`setColumnCount` destroys and recreates `Column 0` whenever toggling between 1 and 2 columns (`Reader.swift:120-154`)**:
   Switching between a 1-column and 2-column layout removes `columns[0].scroll` from the stack and allocates a brand-new `GutterScrollView`, `CodeView`, `NSTextStorage`, `NSLayoutManager`, `NSTextContainer`, and `Gutter` for column 0, instead of keeping column 0 alive and lazily creating/hiding column 1.

### Unenforced Invariants
1. **One `Row` == one TextKit paragraph (`\n`-delimited)**:
   `render()` assumes only its own `\n` between rows starts a new paragraph, and only `.note` rows use `\u{2028}`. However, `displayText()` (`CodeView.swift:149-152`) only replaces `< 0x20` (except tab); it does **not** sanitize `U+2028` (Line Separator), `U+2029` (Paragraph Separator), or `U+0085` (NEL) in `.line` rows, nor `\r` in `.note` rows, nor `\n` in `.header` file paths. Any of these causes `NSLayoutManager` to split a single `Row` into multiple vertical line fragments even when `wraps == false`.
2. **Equal row Y-heights between left and right columns in side-by-side (`split == true`)**:
   `Reader.scrolled` (`Reader.swift:569-576`) synchronizes `columns[0]` and `columns[1]` purely by `clip.bounds.origin.y`. Nothing enforces that row `r` has identical height in both columns:
   - A `.note` row puts its text (including multi-line `\u{2028}`) only on `anchoredSide` and `""` (1 line) on the other side (`CodeView.swift:127`).
   - When `wraps == true`, a long line or note wraps to `K` fragments on one side while its opposite `.filler` or shorter line has `1` fragment.
3. **Trailing empty row (`rowStarts.last == textStorage.length`)**:
   Because `render()` omits `\n` after the last row (`CodeView.swift:134`), whenever the last row has `s == ""` (an empty last source line, a trailing `.filler`, or an unanchored side's `.note`), `rowStarts[rows.count - 1] == textStorage.length`. `rows(in:)`, `visibleRows(in:)`, `selectedRows`, and `identifier(at:)` all break on this boundary.
4. **Non-contiguous layout (`allowsNonContiguousLayout = true`, `CodeView.swift:180`)**:
   `CodeView.rect(ofRow: r)` (`CodeView.swift:301`) calls `lm.ensureLayout(forGlyphRange: NSRange(location: 0, length: min(glyphs.location + 1, lm.numberOfGlyphs)))`, forcing synchronous contiguous layout from glyph 0 on hover, click, and `drawCaret()`.

### How This Fits the Plan's Target Design
- **Step 1 (Confirmed bugs + reader correctness)**: Fix the `drawBackground` layer order bug, `visibleRows` `extraLineFragmentRect` leak, `caretRect` wrapped-line Y bug, `identifier(at:)` cross-row/boundary bug, `selectLines` empty-line bug, `row(for:in:)` recursive `reload` during `toggleShowAll`, `analyzed(file:)` false `reland` across files, `nextFile` stall on notice-only files, `Gutter.numberColumnWidth` truncation, and `Reader.analysis` / `isReadLine` memory retention.
- **Step 2 (Admission limits & lifetimes)**: Enforce per-line UTF-16 width caps (~20k for syntax/wordDiff, bounded preview above ~50 MB / 1M lines) before `render()` builds `plain`, and cancel `Reader.analysis` + child tasks on pane close / `showEmpty`.
- **Step 3 (Cheap UI fast paths)**: Use `layoutManager.replaceTextStorage` on full reload **paired with** shared attribute dictionaries and forward run coalescing in `render()`, stop calling `reload` on review toggles in overview and `toggleWrap`, fix `refreshReadState()` to recolor visible rows once instead of `F` times, bound `analyzeShownFiles` to visible/near-viewport files, and replace `rect(ofRow:)` contiguous layout calls on already-visible rows with `laidOutRect(ofRow:)` / glyph-local layout.

---

## 2. Ranked Findings

### Finding 1: `CodeView.drawBackground` Calls `super.drawBackground` Before Painting Row Backgrounds, Erasing All Word-Diff, Selection, and Find Highlights on Changed Lines in Opaque-Tint Themes
- **Location**: `Sources/SextantApp/CodeView.swift:500-536` (and `Sources/SextantApp/Theme.swift:175-240`)
- **Category**: Bug
- **Plan Step**: Step 1
- **Evidence**:
  In `CodeView.drawBackground(in rect: NSRect)`:
  ```swift
  override func drawBackground(in rect: NSRect) {
      super.drawBackground(in: rect)
      ...
      visibleRows(in: rect) { r, frag in
          ...
          case .line:
              let kind = line(ofRow: r)?.kind
              guard kind == .added || kind == .deleted else { break }
              let changed = kind == .added ? t.color("addLine") : t.color("delLine")
              (isReadLine(rows[r].file, rows[r].line) ? changed.asRead : changed).setFill()
              full.fill()
  ```
  `super.drawBackground(in: rect)` invokes `NSLayoutManager.drawBackground(forGlyphRange:at:)`, which draws temporary `.backgroundColor` attributes (`addWord` / `delWord` set by `color(row:)` at `CodeView.swift:234`), text selection (`selectedTextAttributes`), and Find match highlights. Immediately afterwards, `CodeView.drawBackground` loops over `visibleRows` and paints `full.fill()` with `addLine` / `delLine` **on top of** what `super.drawBackground` just drew.
  - In `Theme.githubLight`, `Theme.githubLightHighContrast`, and `Theme.githubLightColorblind` (`Theme.swift:175-240`), `addLine` (`#dafbe1`, `#d2fedb`, `#ddf4ff`) and `delLine` (`#ffebe9`, `#fff0ee`, `#fff1e5`) are 6-digit hex colors with **`alpha == 1.0`**. Painting `full.fill()` after `super.drawBackground` 100% overwrites and erases all `addWord`/`delWord` highlights, selection highlights, and Find highlights on changed lines.
  - In translucent themes (`Revue Dark` / `Revue Light`), painting `addLine`/`delLine` over `addWord`/`delWord` washes out the word highlight and violates the contrast model in `color(row:)` (`CodeView.swift:235`), which computes contrast for `wordColor.laid(over: lineBackground)` (word over line, not line over word).
  - Verified by `ReaderAuditBench` Test A (`./.build/release/ReaderAuditBench`):
    `[Test A: drawBackground order in GitHub Light] current(super first)=#e0fbe7 (matches addLine #dafbe1, addWord #aceebb ERASED!) | fixed(line first)=#b8efc7 (matches addWord #aceebb!)`
- **Fix**: Draw the `visibleRows` row backgrounds (`addLine`, `delLine`, `emptyLine`/`hatch`, `hunkLine`/pill, `header`, `note`, current-line tint) and `drawOccurrences` **before** calling `super.drawBackground(in: rect)`, then draw `drawUses` and `drawCaret` after `super.drawBackground(in: rect)`.

---

### Finding 2: `CodeView.rect(ofRow:)` Forces Contiguous Layout From Glyph 0 (`0..<glyphs.location + 1`), Defeating `allowsNonContiguousLayout` on `drawCaret()`, Gutter Hover, Pill Hover, and Clicks (684 ms Stall at 100k Rows)
- **Location**: `Sources/SextantApp/CodeView.swift:298-306`, called from `CodeView.swift:452` (`caretRect` <- `drawCaret`), `CodeView.swift:542` (`hoveredPill`), `CodeView.swift:594` (`mouseDown`), `CodeView.swift:1330` (`Gutter.lineRow(at:)` <- `Gutter.mouseMoved`), `Reader.swift:481` (`offsetFromTopPosition`)
- **Category**: Slowness / Architecture
- **Plan Step**: Step 3
- **Evidence**:
  `CodeView.make()` sets `layout.allowsNonContiguousLayout = true` (`CodeView.swift:180`), but `rect(ofRow: r)` (`CodeView.swift:301`) executes:
  ```swift
  lm.ensureLayout(forGlyphRange: NSRange(location: 0, length: min(glyphs.location + 1, lm.numberOfGlyphs)))
  ```
  Whenever `drawBackground(in:)` runs, it calls `drawCaret()` (`CodeView.swift:536`) -> `caretRect` (`CodeView.swift:452`) -> `self.rect(ofRow: r)` even if `caretRow` is off-screen or non-contiguously scrolled. Similarly, moving the mouse over the `Gutter` calls `lineRow(at: event)` -> `code.rect(ofRow: r)` on every `mouseMoved` event (`CodeView.swift:1330, 1354`).
  - Benchmark (`./.build/release/ReaderAuditBench`, Section 3):
    - `1,002 rows`: `laidOutRect` = `0.23 ms` vs `rect(ofRow:)` = `7.04 ms` (**31x slower**)
    - `10,002 rows`: `laidOutRect` = `0.012 ms` vs `rect(ofRow:)` = `69.19 ms` (**5,700x slower**)
    - `50,002 rows`: `laidOutRect` = `0.021 ms` vs `rect(ofRow:)` = `348.83 ms` (**16,600x slower**)
    - `100,002 rows`: `laidOutRect` = `0.027 ms` vs `rect(ofRow:)` = `684.26 ms` (**25,400x slower**)
- **Fix**:
  - In `drawCaret()`, `caretRect`, `hoveredPill`, `CodeView.mouseDown`, and `Gutter.lineRow(at:)`, use `laidOutRect(ofRow:)` (or `lm.ensureLayout(forGlyphRange: glyphs)` for just the target row's glyph range, never `0..<glyphs.location + 1`).
  - In `drawCaret()`, skip drawing entirely if `laidOutBounds(ofRow: r)` is `nil` or does not intersect the `dirtyRect` passed to `drawBackground(in:)`.

---

### Finding 3: `Reader.analyzeShownFiles` Runs an O(F²) `@MainActor` Scheduling Loop (6.1 s at 10k Files, 24.4 s at 20k Files), Retains Closed `Reader` Instances Strongly, and `analyzed(file:)` Re-lands the Caret on Every Off-Screen File Completion
- **Location**: `Sources/SextantApp/Reader.swift:191-239`, `Sources/SextantApp/RepoWindowController.swift:779-784`
- **Category**: Slowness / Bug / Memory Retention
- **Plan Step**: Step 1, Step 2, Step 3
- **Evidence**:
  1. **O(F²) `@MainActor` scheduling + layout queries**:
     In `analyzeShownFiles()` (`Reader.swift:191-214`), the `while` loop runs `F` times on `@MainActor`. Each iteration calls `nextToAnalyze`, which queries `currentFile` -> `topRow(primary)` (`NSLayoutManager` glyph lookup), allocates a filtered `[Int]` over all `shown.indices`, scans `.min` over it, and after `await f.analyze(...)` runs `files.firstIndex(where: { $0 === f })` (another O(F) scan).
     - Benchmark (`./.build/release/ReaderAuditBench`, Section 4):
       - `1,000 files`: `62.68 ms`
       - `5,000 files`: `1,532.74 ms (1.53 s)`
       - `10,000 files`: `6,105.15 ms (6.11 s)`
       - `20,000 files`: `24,448.15 ms (24.45 s)` of pure main-thread overhead.
  2. **Bug in `analyzed(file: fi)` (`Reader.swift:218-225`)**:
     ```swift
     private func analyzed(file fi: Int) {
         let reland = landedSelection != nil && landedSelection == keptSelection
         for c in columns { c.code.recolor(file: fi) }
         if reland, let r = caretRow { placeCaret(atRow: r) }
         updateHeader()
         if boxed == nil, caret?.file == fi { updateOccurrences() }
     }
     ```
     `reland` does **not** check `caret?.file == fi`! When the caret was placed by `placeCaret` on file 0 in the overview, `landedSelection == keptSelection` is `true`. As files `fi = 1, 2, ..., F-1` finish analyzing off-screen, **every single file completion calls `placeCaret(atRow: r)` on file 0**, which calls `setSelectedRange`, fires `codeViewCaretMoved`, cancels and restarts the 100 ms `pendingOccurrences` timer (`caretMovedAmongNames()`), and calls `recolor(file: fi)` -> `colorVisibleRows()` and `updateHeader()` even when `fi` is nowhere near the viewport.
  3. **Memory retention on `showEmpty` and pane close (`Reader.swift:192, 228-239, 256`, `RepoWindowController.swift:779-784`)**:
     - `analysis = Task { ... }` (`Reader.swift:192`) captures `self` (`Reader`) **strongly** (no `[weak self]`) and `let shown = files`.
     - Neither `Reader.showEmpty` (`Reader.swift:228`) nor `RepoWindowController.discard(_ closed: [Pane])` (`RepoWindowController.swift:779`) cancels `analysis` or `pendingOccurrences`. Closing a pane leaves the detached `Reader`, its `CodeView`s, `NSTextStorage`, and `[FileState]` alive until every file in `shown` finishes analyzing.
     - `Reader.showEmpty` sets `self.files = []` and `c.code.files = []`, but does not reset `c.code.isReadLine`, which strongly captures `let files = self.files` from the last `reload()` (`Reader.swift:256`), retaining all previous `FileState` objects while the reader shows an empty state.
- **Fix**:
  - Only analyze files currently visible or near the viewport (triggered from coalesced scroll/settle, per Plan Step 3), using `[weak self]` in `analysis = Task`.
  - In `analyzed(file: fi)`, guard `reland` with `caret?.file == fi`, and only call `colorVisibleRows()` / `updateHeader()` when `fi` overlaps `rowsNearView` or `currentFile`.
  - Cancel `analysis` and `pendingOccurrences` and reset `c.code.isReadLine = { _, _ in false }` in `showEmpty` and when discarding a pane.

---

### Finding 4: `render()` Allocates Per-Row Attribute Dictionaries and `NSMutableParagraphStyle`s and Splits `NSRLEArray` `extras.count` Times; `displayText()` Is 68x Slower on Lines With `\r`
- **Location**: `Sources/SextantApp/CodeView.swift:84-152`
- **Category**: Waste / Slowness
- **Plan Step**: Step 3
- **Evidence**:
  1. Plan Step 3 swaps `textStorage?.setAttributedString(r.string)` for `layoutManager.replaceTextStorage`. Our benchmark confirms `replaceTextStorage` drops the `NSTextStorage` install step at 10k files from `199.93 ms` to `0.94 ms`, **but `render()` itself still takes `66.09 ms` at 10k files and `193.15 ms` at 25k files** because:
     - Every `.header`, `.fold`, `.gap`, and `.note` row allocates a fresh `[NSAttributedString.Key: Any]` dictionary via `.merging([.sextantAction: ...])`, and every `.header` allocates a new `NSMutableParagraphStyle` (`style.paragraph(...)`).
     - `render()` appends one giant `plain` string with `base` attributes and then loops `for (r, a) in extras { text.setAttributes(a, range: ...) }` (`CodeView.swift:140`), splitting `NSMutableAttributedString`'s `NSRLEArray` `2 * F` times.
     - Removing `.sextantAction` from `NSAttributedString` (deriving `ReaderAction` from `rows[r]` in `CodeView.mouseDown` at `CodeView.swift:593-597`), pre-creating the 2 header attribute dictionaries (`ri == 0` and `ri > 0`), and building `NSTextStorage` in a single forward pass cuts total 10k-file render+install time to `45.41 ms` (`./.build/release/ReaderAuditBench`, Section 1).
  2. In `displayText(_ s: String)` (`CodeView.swift:149-152`):
     Because `Parse.swift:202` preserves `\r` on patch lines of CRLF files, every line of a CRLF diff hits the slow path `String(String.UnicodeScalarView(s.unicodeScalars.map ...))`, which allocates a mapped scalar buffer per line:
     - Benchmark (`./.build/release/ReaderAuditBench`, Section 2, 100k lines): `5.21 ms` on LF lines vs **`336.26 ms`** on CRLF lines (**64.5x slower**).
- **Fix**:
  - Derive `ReaderAction` directly from `rows[r]` in `CodeView.mouseDown` instead of storing `.sextantAction` in `NSAttributedString`; hoist `headerFirstAttrs`, `headerRestAttrs`, and `noteAttrs` outside the row loop in `render()`.
  - Reserve capacity on `plain` (`plain.reserveCapacity(rows.count * 48)`), and return an `NSTextStorage` directly from `render()` to pass into `layoutManager.replaceTextStorage`.

---

### Finding 5: `Reader.refreshReadState()` Calls `c.code.recolor(file: i)` in a Loop Over All `files.indices`, Running `colorVisibleRows()` and Layout Queries `F` Times; `isReadLine` Scans `keyedRuns` Linearly and Allocates `reviewKey` Strings on Every Draw
- **Location**: `Sources/SextantApp/Reader.swift:256, 283-289`, `Sources/SextantApp/CodeView.swift:188-193, 227, 515, 1265`, `Sources/SextantApp/RepoWindowController.swift:873-874`
- **Category**: Waste / Slowness
- **Plan Step**: Step 3
- **Evidence**:
  1. In `Reader.refreshReadState()` (`Reader.swift:283-289`):
     ```swift
     func refreshReadState() {
         for c in columns {
             for i in files.indices { c.code.recolor(file: i) }
             ...
     ```
     Each call to `c.code.recolor(file: i)` (`CodeView.swift:188-193`) bisects `rows`, removes `range` from `colored`, and immediately calls `colorVisibleRows()` (which queries `NSLayoutManager.glyphRange(forBoundingRect:in:)` and `characterRange(forGlyphRange:)` and colors visible rows on `i = 0`, then repeats the layout query `F - 1` more times!).
     - Benchmark (`./.build/release/ReaderAuditBench`, Section 5):
       - `1,000 files`: `2.92 ms` vs `0.0055 ms` for `recolorAll()` (**530x slower**)
       - `10,000 files`: `21.17 ms` vs `0.0048 ms` (**4,410x slower**)
       - `25,000 files`: `52.70 ms` vs `0.0055 ms` (**9,580x slower**)
     - Furthermore, in `RepoWindowController.reviewsChanged` (`RepoWindowController.swift:873-874`), right after calling `p.reader.refreshReadState()`, if `p.focus` is `.overview`, it calls `p.reader.reload(keepPosition: true)` — even though **nothing in `layoutRows` or `render` depends on `reviewed` or `isRead`**! Only `refreshReadState()` and `updateHeader()` are needed.
  2. In `Reader.reload` (`Reader.swift:256`), `c.code.isReadLine` is set to:
     `{ fi, li in files[fi].run(at: li).map { isRead(files[fi], $0) } ?? false }`
     This closure is called **3 times per visible changed line** (in `CodeView.color(row:)`, `CodeView.drawBackground`, and `Gutter.drawHashMarksAndLabels`). Each call linearly scans `files[fi].keyedRuns.first { $0.run.lines.contains(line) }` and constructs a fresh `RawChange.reviewKey` string interpolation (`Model.swift:32`).
     - Benchmark (`./.build/release/ReaderAuditBench`, Section 7, 80 visible lines × 3 call sites):
       - `1,000 runs`: `6.52 ms` per frame vs `< 0.001 ms` with cached read state / binary search.
       - `5,000 runs`: `33.62 ms` per frame (exceeds two 60 Hz frame budgets).
- **Fix**:
  - Replace the loop in `refreshReadState()` with `c.code.recolorAll()` (which does `colored.removeAll(); colorVisibleRows()` once), and in `RepoWindowController.reviewsChanged` call `p.reader.updateHeader()` instead of `p.reader.reload(keepPosition: true)`.
  - Binary-search `keyedRuns` by `run.lines` in `FileState.run(at:)`, cache `reviewKey` as a stored `let` on `RawChange`, and cache per-run read booleans on `FileState`.

---

### Finding 6: `CodeView.color(row:)` Returns `false` While `f.tokens == nil`, Preventing `colored.insert(r)` and Re-Running Word Diffs and `makeReadable` on Every Scroll Notification
- **Location**: `Sources/SextantApp/CodeView.swift:181-185, 212-254`
- **Category**: Waste / Bug
- **Plan Step**: Step 3
- **Evidence**:
  In `colorVisibleRows()` (`CodeView.swift:181-185`):
  ```swift
  for r in near where !colored.contains(r) {
      if color(row: r, lm) { colored.insert(r) }
  }
  ```
  And at the end of `color(row: r, lm)` (`CodeView.swift:253`):
  ```swift
  return f.tokens != nil || !f.hasLanguage
  ```
  While a file with a grammar (`f.hasLanguage == true`) is awaiting background syntax analysis (`f.tokens == nil`), `color(row: r, lm)` strips temporary attributes, queries `isReadLine`, computes/applies `f.wordRanges(row.line)`, and runs `makeReadable`, then returns `false`. Because it returns `false`, `colored.insert(r)` is not called.
  Consequently, **every single `scrolled` notification while `f.tokens == nil` re-runs `color(row:)` on all ~120 rows in `rowsNearView`**, even though `analyzed(file:)` already calls `recolor(file:)` (which clears `colored` for that file) when `f.tokens` arrives!
  - Benchmark (`./.build/release/ReaderAuditBench`, Section 9b): Over 100 scroll ticks across 120 rows while `tokens == nil`, returning `false` takes `19.70 ms` vs `0.23 ms` when inserting into `colored` (**85x wasted work**).
- **Fix**: Always insert `r` into `colored` once `color(row: r, lm)` has applied current temporary attributes (since `recolor(file:)` invalidates `colored` when `tokens` arrives). Compute `awaitsColors` (`CodeView.swift:208`) by checking whether any row in `rowsInView` belongs to a file where `f.hasLanguage && f.tokens == nil`.

---

### Finding 7: `Reader.row(for:in:)` Auto-Unfolds Folds and Recursively Calls `reload(keepPosition: false)` During `toggleShowAll`, Re-Rendering Twice, Defeating Re-Folding, and Clobbering the Caret
- **Location**: `Sources/SextantApp/Reader.swift:240-268, 491-502`, `Sources/SextantApp/WindowActions.swift:625-628`
- **Category**: Bug / Architecture
- **Plan Step**: Step 1
- **Evidence**:
  When the user is viewing an unchanged region of a file with `Show All Lines` enabled (`showAll == true`) and toggles `Show All Lines` off (`WindowActions.swift:626`):
  1. `reader.showAll.toggle()` sets `showAll = false` (note: `f.unfolded` is also never cleared).
  2. `reader.reload(keepPosition: true)` saves `pos = topPosition` (an unchanged line) and `kept = keptSelection`, then lays out and renders the newly folded document.
  3. At `Reader.swift:262`, `reload` calls `if let pos { scroll(to: pos, animated: false, offset: topOffset) }`.
  4. `scroll(to: pos)` calls `row(for: pos, in: primary)` (`Reader.swift:491-502`):
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
     Because `pos.line` now lies inside the fold that `layoutRows` just created, `row(for: pos)` **inserts that fold into `files[p.file].unfolded` and recursively calls `reload(keepPosition: false)`**!
  5. The inner `reload(keepPosition: false)` renders the whole document a second time (with the fold re-opened!) and resets selection to `NSRange(location: 0, length: 0)`. If `kept` in the outer `reload` was on an unchanged line in a different fold, `restore(kept)` (`Reader.swift:431`) fails to find a `.line` row for `kept` and leaves the caret clobbered at `0`.
- **Fix**:
  - Separate pure row lookup `row(for: p, in: code, unfold: Bool = false)` from mutating unfold operations.
  - When `keepPosition: true` restores `topPosition` or `keptSelection` after a fold change (`toggleShowAll`), do **not** auto-unfold; clamp `topPosition` / `keptSelection` to the `.fold` row or nearest visible `.line` row. When `showAll` transitions from `true` to `false`, clear `f.unfolded` so previously opened folds actually close.

---

### Finding 8: `CodeView.visibleRows(in:)` Unconditionally Appends `extraLineFragmentRect` Whenever the Last Row Is Empty (`s == ""`), Leaking the Document's Last Row Into Every Viewport Query
- **Location**: `Sources/SextantApp/CodeView.swift:318-336` (also affects `CodeView.swift:202-206`)
- **Category**: Bug
- **Plan Step**: Step 1
- **Evidence**:
  In `CodeView.visibleRows(in rect: NSRect, _ body: (Int, NSRect) -> Void)` (`CodeView.swift:332-334`):
  ```swift
  if lm.extraLineFragmentRect.height > 0, let last = rows.indices.last, rowStarts[last] >= (textStorage?.length ?? 0) {
      spans.append((last, lm.extraLineFragmentRect.offsetBy(dx: 0, dy: origin.y)))
  }
  ```
  Whenever the last row of the document has empty text `s == ""` (e.g., a trailing empty source line, a trailing `.filler` row in side-by-side mode, or a `.note` row on the non-anchored side) and the end of the document has been laid out (`extraLineFragmentRect.height > 0`), `visibleRows(in: rect)` appends `last` **without checking if `extraLineFragmentRect.offsetBy(dx: 0, dy: origin.y)` intersects `rect`**.
  - Verified by `ReaderAuditBench` Test B (`./.build/release/ReaderAuditBench`):
    `[Test B: visibleRows extraLineFragmentRect leak] querying top viewport y=0..200 returned rows: 0...10 PLUS trailing row=999 at y=18981.0!`
  - Consequences:
    - `CodeView.drawBackground(in: rect)` and `Gutter.drawHashMarksAndLabels(in: rect)` draw the last row's background/gutter on every partial redraw at the top of the document.
    - `Reader.jumpTargets(_:)` (`Reader.swift:395`) searches `rows.last` even when it is thousands of lines off-screen.
  - Related boundary bug in `rows(in rect: NSRect)` (`CodeView.swift:202-206`):
    - Because `NSMaxRange(chars) <= textStorage.length == rowStarts[last]`, `max(chars.location, NSMaxRange(chars) - 1)` is at most `textStorage.length - 1`, so `row(at:)` returns `last - 1` instead of `last`. Thus `rowsInView` / `rowsNearView` never includes a trailing empty row `last`!
    - If a file has 1 empty line (`rows.count == 1`, `textStorage.length == 0`), `guard let length = textStorage?.length, length > 0` returns `nil`, and `Reader.row(atY:)` (`Reader.swift:458`) calls `lm.characterIndexForGlyph(at: 0)` when `lm.numberOfGlyphs == 0`.
- **Fix**:
  - In `visibleRows(in: rect)`, check `let extra = lm.extraLineFragmentRect.offsetBy(dx: 0, dy: origin.y); if extra.intersects(rect)` before appending `last`, and guard `glyphs.location < lm.numberOfGlyphs` before calling `lm.characterIndexForGlyph(at:)`.
  - In `Reader.row(atY:in:)`, guard `lm.numberOfGlyphs > 0` before calling `lm.glyphIndex(for:in:)` and `lm.characterIndexForGlyph(at:)`.

---

### Finding 9: `CodeView.caretRect` Uses `self.rect(ofRow: r).minY` (First Line Fragment) Instead of the Caret Glyph's Line Fragment, Drawing the Caret Box on the Wrong Visual Line When `wraps == true`
- **Location**: `Sources/SextantApp/CodeView.swift:442-454` (and `CodeView.swift:432-435`)
- **Category**: Bug
- **Plan Step**: Step 1
- **Evidence**:
  In `CodeView.caretRect` (`CodeView.swift:442-454`):
  ```swift
  let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
  var rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
  if range.length == 0 { rect.size.width = style.digitWidth }
  rect.origin.x += textContainerOrigin.x
  rect.origin.y += textContainerOrigin.y
  let frag = self.rect(ofRow: r)
  return NSRect(x: rect.minX - 2, y: frag.minY + 1, width: rect.width + 4, height: min(frag.height, style.lineHeight) - 2)
  ```
  `self.rect(ofRow: r)` returns the line fragment rect at `rowStarts[r]` — which is always the **first** wrapped visual line of row `r`. When `wraps == true` and the caret is on a token on the 2nd, 3rd, or Nth wrapped visual line of row `r`, `caretRect` uses `x` from the Nth visual line (`rect.minX - 2`) but **`y` from the 1st visual line (`frag.minY + 1`)**!
  - Verified by `ReaderAuditBench` Test D (`./.build/release/ReaderAuditBench`):
    `[Test D: caretRect wrapped line Y bug] token at char 160 is at y=114.0 (fragY=115.0), but CodeView.caretRect draws it at y=1.0!`
  - Similarly, in `CodeView.setSelectedRanges` (`CodeView.swift:432-435`), `guard let line = laidOutRect(ofRow: r)` only invalidates `line.height + style.lineHeight` (the first 2 fragments of row `r`), leaving the current-line highlight and caret dirty on wrapped fragments 3+.
- **Fix**:
  - In `caretRect`, obtain `frag` from the glyph where the caret actually sits (`lm.lineFragmentRect(forGlyphAt: min(glyphs.location, max(0, lm.numberOfGlyphs - 1)), effectiveRange: nil, withoutAdditionalLayout: true)` offset by `textContainerOrigin.y`).
  - In `setSelectedRanges`, invalidate `laidOutBounds(ofRow: r)` (which covers all wrapped fragments of row `r`) instead of `laidOutRect(ofRow: r)`.

---

### Finding 10: `CodeView.identifier(at:)` Crosses Row Boundaries on Empty Rows and Matches Identifiers Two Characters Left at `textStorage.length`
- **Location**: `Sources/SextantApp/CodeView.swift:1054-1067`
- **Category**: Bug
- **Plan Step**: Step 1
- **Evidence**:
  ```swift
  func identifier(at index: Int) -> NSRange? {
      guard let s = textStorage?.string as NSString?, s.length > 0 else { return nil }
      ...
      var i = min(index, s.length - 1)
      if !isIdent(i) { i -= 1 }
      guard isIdent(i) else { return nil }
  ```
  1. When the last row of the document is empty (`rowStarts[last] == s.length`) and the caret is on that empty last row (`index == s.length`), `min(index, s.length - 1)` is `s.length - 1` (the `\n` at the end of row `last - 1`), and `if !isIdent(i) { i -= 1 }` steps back to `s.length - 2` — matching an identifier at the end of **the previous row (`last - 1`)**!
  2. When the caret is at the end of the document (`index == s.length`) after a non-identifier punctuation character (e.g. `return foo;` where `s.length - 1` is `;`), `min(index, s.length - 1)` lands on `;`, and `if !isIdent(i) { i -= 1 }` steps back a **second** time onto `o`, returning `"foo"` even though the caret is after `;`!
  - Verified by `ReaderAuditBench` Test E (`./.build/release/ReaderAuditBench`):
    `[Test E: identifier(at:) boundary bugs] at empty row 1 start (idx=11): matched 'foo' on row 0! At end of 'return foo;' (idx=11): matched 'foo' past ';'!`
  - While `caretRect` (`CodeView.swift:445`) worked around this by checking `NSLocationInRange($0.location, line)`, callers in `Reader.nameAtCaret` (`Reader.swift:278`), `Reader.wordAtCaret` (`Reader.swift:448`), `Reader.stepUse` (`Reader.swift:345`), `CodeView.mouseDown` (`CodeView.swift:599`), and `CodeView.identifierStart` (`CodeView.swift:684`) do not!
- **Fix**: In `identifier(at: index)`, look up `guard let r = row(at: index) else { return nil }` and clamp `isIdent(_:)` to `charRange(ofRow: r)` (and only check `index` and `index - 1`, never `s.length - 2`).

---

### Finding 11: Selecting an Empty Line (`""`) via `V` (`toggleLineSelection`) or Gutter Click Produces `selectedRange().length == 0`, Breaking Gutter Note Badges and Trapping the User in `V` Mode (`Escape` Cannot Exit)
- **Location**: `Sources/SextantApp/CodeView.swift:631, 640-653, 1086-1091, 1239, 1360`
- **Category**: Bug
- **Plan Step**: Step 1
- **Evidence**:
  For any `.line` row `r` whose text is empty (`""`), `charRange(ofRow: r)` (`CodeView.swift:291-295`) returns `NSRange(location: rowStarts[r], length: 0)`.
  When the user presses `V` (`toggleLineSelection()`, `CodeView.swift:640`) or clicks a line number in the `Gutter` (`CodeView.swift:1368`) on an empty line:
  - `selectLines(from: r, to: r)` (`CodeView.swift:647-653`) sets `selectedRange` to `NSRange(location: rowStarts[r], length: 0)` (`length == 0`).
  - `Gutter.drawHashMarksAndLabels` (`CodeView.swift:1239`) checks `code.selectedRange().length > 0 ? code.selectedRows.last : nil`, so no `+` Add Note badge is drawn for the selected empty line.
  - `CodeView.keyDown` (`CodeView.swift:631`) handles `Escape` (`\u{1b}`) with:
    `if selectedRange().length > 0 { collapseSelection(); return }`
    Because `selectedRange().length == 0`, pressing `Escape` does **not** call `collapseSelection()`, leaving `lineSelectionStart != nil` so subsequent `j`/`k` presses unexpectedly extend a multi-line selection instead of moving the caret.
  - Additionally, when `selectLines(from: a, to: b)` ends on an empty line `hi` (`b >= a`), `NSMaxRange(charRange(ofRow: hi))` is `rowStarts[hi]`, so `selectedRows` (`CodeView.swift:1089`: `row(at: NSMaxRange(sel) - 1)`) resolves `rowStarts[hi] - 1` to row `hi - 1`, **dropping the empty line `hi` from `selectedRows` and `Reader.selection`**!
- **Fix**:
  - In `selectLines(from: a, to: b)`, include the trailing `\n` of row `hi` when `charRange(ofRow: hi).length == 0` and `rowStarts[hi] < (textStorage?.length ?? 0)` (or track selected line ranges via `lineSelectionStart` / explicit row selection state), and in `keyDown` check `if selectedRange().length > 0 || lineSelectionStart != nil { collapseSelection(); return }`.

---

### Finding 12: Unicode Line/Paragraph Separators (`U+2028`, `U+2029`, `U+0085`), Multi-Line Notes, and `wraps == true` Desynchronize Side-by-Side (`split == true`) Columns
- **Location**: `Sources/SextantApp/CodeView.swift:115, 127, 149-152`, `Sources/SextantApp/Reader.swift:569-576`
- **Category**: Bug
- **Plan Step**: Step 1
- **Evidence**:
  1. `displayText(_ s: String)` (`CodeView.swift:149-152`) only replaces scalars with `$0.value < 32 && $0.value != 9`. It leaves `U+2028` (Line Separator), `U+2029` (Paragraph Separator), and `U+0085` (Next Line) untouched. `NSLayoutManager` treats all three as hard line/paragraph breaks even when `wraps == false`.
     - Verified by `ReaderAuditBench` Test F (`./.build/release/ReaderAuditBench`):
       `[Test F: U+2028 Line Separator in single .line row with wraps=false] displayTextOriginal kept U+2028 -> NSLayoutManager produced 2 vertical line fragments for 1 row (desyncs side-by-side)!`
  2. In `render()` (`CodeView.swift:127`):
     ```swift
     case .note(let id):
         let anchoredSide = files[row.file].lines[row.line].kind == .deleted ? 0 : 1
         s = side < 0 || side == anchoredSide ? (notes[id]?.text ?? "").replacingOccurrences(of: "\n", with: "\u{2028}") : ""
     ```
     In side-by-side (`side == 0` or `1`), if a note has `K > 1` lines (or contains `\r`), `anchoredSide` lays out `K` line fragments (`K * lineHeight`), while the opposite column lays out `""` (`1 * lineHeight`), permanently shifting every subsequent row in the two columns by `(K - 1) * lineHeight` pixels.
- **Fix**:
  - In `displayText()`, also replace `U+0085`, `U+2028`, and `U+2029` with visible symbol pictures (e.g. `U+2424`), and apply `displayText` to `.header` paths and `.notice` strings.
  - In `render()` for `.note(let id)` when `side >= 0 && side != anchoredSide`, emit as many `\u{2028}` separators as the note has line breaks (after normalizing `\r\n` and `\r` to `\n`) so both columns have identical vertical height for the note row.

---

### Finding 13: `Reader.show` Lays Out and Colors at the Old Scroll Offset Before Scrolling to Top/Target, and `RepoWindowController.present` Scrolls and Queries Layout 3x Per File Open
- **Location**: `Sources/SextantApp/Reader.swift:175-184, 520-532`, `Sources/SextantApp/RepoWindowController.swift:627-643`
- **Category**: Waste / Slowness
- **Plan Step**: Step 3
- **Evidence**:
  In `Reader.show(files:overview:at:)` (`Reader.swift:175-184`):
  ```swift
  reload(keepPosition: false)
  if let position { scroll(to: position, animated: false) } else { scrollToTop() }
  ```
  When switching from a scrolled document (say at `Y = 40,000`) to a new file or overview:
  1. `reload(keepPosition: false)` runs `setContent` -> `colorVisibleRows()` while `scroll.contentView.bounds.origin.y` is **still at `Y = 40,000`**, forcing `NSLayoutManager` to lay out the new document down to `Y = 40,000` and color rows there.
  2. Next, `scrollToTop()` resets `bounds.origin.y` to `0`, firing `scrolled(_:)` -> `colorVisibleRows()` + `updateHeader()` at `Y = 0`.
  3. Next, in `RepoWindowController.present` (`RepoWindowController.swift:629-641`), because `present` calls `reader.show(files: [f], overview: false)` without `at:` and then immediately calls `reader.scroll(to:)` or `reader.scrollToFirstChange()`, it scrolls and lays out a **third** time!
- **Fix**:
  - In `reload(keepPosition: false)` (when not preserving position), reset `c.scroll.contentView.setBoundsOrigin(.zero)` **before** calling `c.code.setContent(...)`, or pass the target `ReaderPosition` into `show(files:overview:at:)` so scroll positioning happens once before `colorVisibleRows()`.
  - Wrap `scrollColumns` in `syncing = true ... syncing = false` so programmatic two-column scrolls do not re-entrantly trigger `scrolled(_:)` per column.

---

### Finding 14: Linear `code.rows` Scans in `Reader`, Linear Line Scans in `CodeView.stepName`, and Repeated `Gutter.numberColumnWidth` Reductions (With a Truncation Bug on `.deleted`/`.added` Last Lines)
- **Location**: `Sources/SextantApp/Reader.swift:309, 432, 442, 450, 491-502, 661`, `Sources/SextantApp/CodeView.swift:665-682, 1190-1194`
- **Category**: Slowness / Bug
- **Plan Step**: Step 1, Step 3
- **Evidence**:
  1. **Linear `code.rows` scans (`Reader.swift:491-502`, etc.)**:
     `Reader.row(for:in:)` runs up to 3 linear `rows.firstIndex(where:)` scans over all rows (`400,000` rows at 50k files takes `14.44 ms` per lookup vs `0.00037 ms` with binary search: **39,000x faster**, Section 6 of `ReaderAuditBench`).
  2. **`CodeView.stepName` (`w`/`b` keys, `CodeView.swift:665-682`)**:
     Loops line-by-line until an identifier is found, allocating `textStorage?.attributedSubstring(from: range).string` and calling `identifiers(in:tokens:)` on every line (`42.31 ms` across 10k comment/JSON lines, Section 8 of `ReaderAuditBench`). Reading `files[rows[r].file].lines[rows[r].line].text` directly avoids allocating an `NSAttributedString` and `String` per skipped line, and `stepName` should cap how many lines it scans on a single keypress.
  3. **`Gutter.numberColumnWidth` truncation bug and repeated O(F) reduction (`CodeView.swift:1190-1194`)**:
     ```swift
     private var numberColumnWidth: CGFloat {
         let maxNo = code.files.reduce(1) { max($0, $1.lines.last.map { max($0.oldNo, $0.newNo) } ?? 1) }
     ```
     - **Bug**: On a `.deleted` line, `newNo == 0`; on an `.added` line, `oldNo == 0` (`Parse.swift:206-208`). Inspecting only `$1.lines.last` undercounts digits whenever a hunk's last line is `.deleted` (`oldNo < 1000, newNo == 0`) after earlier `.added` lines reached `newNo >= 1000` (or vice-versa). Verified by `ReaderAuditBench` Test G: `buggyMaxNo=950 (3 digits) vs actualMaxNo=1050 (4 digits)!`
     - **Waste**: `numberColumnWidth` reduces all `code.files` (`4.64 ms` at 50k files) and is recomputed 2–4x per gutter draw and resize (`updateThickness` -> `blameWidth` -> `numberColumnWidth`, `drawHashMarksAndLabels` -> `numberColumnWidth` + `blameWidth`).
- **Fix**:
  - Expose `CodeView.rowRange(ofFile:)` to `Reader` so `row(for:in:)`, `restore`, `rect(file:line:)`, `scrollToFile`, and `unfoldNearest` only inspect the target file's row slice `[Range<Int>]`.
  - Compute each file's max line number from its last non-deleted line's `newNo` and last non-added line's `oldNo`, and cache `maxLineNumber` once per `setContent`.

---

### Finding 15: Navigation & UI Edge-Case Bugs in `Reader` and `CodeView` (`nextFile`, `stepDefinition`, `currentNewLine`, `unfoldNearest`, `toggleWrap`, `carryCaretIntoView`, `Gutter.hoverRow`, `copy`, `jump`)
- **Location**:
  - `Reader.swift:37, 306-314, 370-390, 651-691, 712-716`
  - `CodeView.swift:687-717, 1070-1083, 1325, 1354`
  - `WindowActions.swift:630-634`
- **Category**: Bug / Waste
- **Plan Step**: Step 1, Step 3
- **Evidence**:
  1. **`Reader.nextFile` (`Shift+L`) gets stuck on binary/empty/notice-only files in overview (`Reader.swift:651-665`)**:
     In `scrollToFile(_ fi: Int)`, `if let first = code.rows[r...].firstIndex(where: { $0.file == fi && $0.kind == .line }) { placeCaret(atRow: first) }` does not move the caret when file `fi` has only `.header` + `.notice` rows. If the previous file `fi - 1`'s caret is still visible on screen (`caretInView == true`), pressing `Shift+L` (`nextFile(1)`) reads `from = caretInView ? caretRow : topRow(code)` -> `fi - 1` and jumps to `fi` again forever.
     - **Fix**: In `scrollToFile(_ fi: Int)`, if file `fi` has no `.line` row, place the caret on its `.notice` or `.header` row (or update `activeColumn`'s selection to `rowStarts[r]`).
  2. **`Reader.stepDefinition` ignores `caretInView` (`Reader.swift:675, 683`), and `currentNewLine` passes old-side line numbers into new-side symbol lookup on deleted lines (`Reader.swift:712-716`)**:
     - At `Reader.swift:675`: `let here = caret.map { ... } ?? currentNewLine ?? 0` never reaches `currentNewLine` when `caret != nil`, even if the user scrolled far away from the caret (`caretInView == false`). Same in `stepChangedDefinition` (`Reader.swift:683`: `let here = caret?.line ?? topPosition?.line ?? 0`). Use `(caretInView ? caret : nil)` in both.
     - At `Reader.swift:715`: `currentNewLine` returns `max(0, $0.oldNo - 1)` when `$0.newNo == 0` (deleted line) and passes it to `header.updateSymbol(line:)` which searches new-side `definitions`. Use the nearest preceding/following non-deleted line's `newNo - 1` instead.
  3. **`Reader.unfoldNearest()` unfolds folds in other files in overview and omits `delegate?.readerUnfolded(self)` (`Reader.swift:306-314`)**:
     Filters `code.rows.indices` across the entire overview instead of `code.rowRange(ofFile: code.rows[r].file)`.
  4. **`WindowActions.toggleWrap` calls `reader.reload(keepPosition: true)` unnecessarily (`WindowActions.swift:630-634`)**:
     `reader.wraps.toggle()` already updates `c.code.wraps` (`didSet` at `Reader.swift:37`), which re-wraps `NSTextContainer` in place; `reload` redundantly rebuilds all `Layout` and `RenderedText`.
  5. **`CodeView.carryCaretIntoView()` passes `NSNullRect` when `visibleRect.height < 2 * style.lineHeight` and forgets to update `anchorIndex`/`headIndex` (`CodeView.swift:712-717`)**:
     Guard `visibleRect.height > 2 * style.lineHeight` before `.insetBy(dx: 0, dy: style.lineHeight)`, and update `anchorIndex` and `headIndex` when moving the caret.
  6. **`Gutter.hoverRow.didSet` invalidates the entire `Gutter` view on every mouse move (`CodeView.swift:1325`)**:
     `hoverRow` sets `needsDisplay = true` on the whole `Gutter` (redrawing all visible line numbers and blame strings and recreating the `"plus"` `NSImage` in `drawAddBadge`) instead of invalidating only the old and new hovered row rects (as `CodeView.hoveredPill` does at `CodeView.swift:542`).
  7. **`CodeView.copy(_:)` clears the pasteboard when only non-`.line` rows are selected (`CodeView.swift:1070-1083`)**:
     Guard `!out.isEmpty` before calling `NSPasteboard.general.clearContents()`.
  8. **`Reader.handleJump` does not filter `col.code.jumpLabels` after the first key of a 2-key label and `CodeView.mouseDown` does not cancel an active jump (`Reader.swift:386-389`, `CodeView.swift:590`)**:
     Filter `col.code.jumpLabels` to labels with `.hasPrefix(t)` in `.picking`, and cancel `jump` on `mouseDown`.

---

## 3. Correctness Edge Cases That Performance Rewrites Could Break

1. **Swapping `NSTextStorage` via `layoutManager.replaceTextStorage` (Step 3)**:
   - `NSTextView` caches `selectedRanges`, typing attributes, and find-bar client state against the current `NSTextStorage`. When replacing `textStorage` via `layoutManager.replaceTextStorage(freshStorage)`, reset selection to `(0, 0)` (or clamped target range) **before** or immediately with replacement so `NSTextView` never holds an `NSRange` past `freshStorage.length`.
2. **Per-block overview text edits or lazy file unfolding (Steps 3 & 8)**:
   - `CodeView.rowStarts` (`[Int]`), `colored` (`IndexSet`), `occurrences` (`[RowRange]`), `lineRows` (`[Int: [Int32]]`), `uses` (`[NSRange]`), and `Reader.changeStops` (`[Int]`) are all indexed by absolute `row` index and absolute UTF-16 character offset. Any partial/in-place mutation of `NSTextStorage` or `rows` for one file in the overview must shift `rowStarts`, `colored`, `occurrences`, `uses`, and `changeStops` for all subsequent files, or derive offsets per-file.
3. **Removing `.sextantAction` from `NSAttributedString` (Step 3)**:
   - `.cursor: NSCursor.pointingHand` on `.fold`, `.gap`, `.header`, and `.note` rows is used by `NSTextView` to show the pointing-hand cursor. Keep `.cursor: NSCursor.pointingHand` on those shared attribute dictionaries while resolving the `ReaderAction` on click from `rows[r]`.
4. **Coalescing scroll notifications (Step 3)**:
   - In side-by-side mode (`columns.count == 2`), `scrolled(_:)` does **two** things: (a) syncs the opposite column's `NSClipView.bounds.origin` (`Reader.swift:571-574`) and (b) colors visible rows and updates `PaneHeader` / `Inspector` (`Reader.swift:577-581`). Clip-view `bounds.origin` syncing between the two columns **must remain synchronous per frame** to prevent visual tearing between the left and right columns while scrolling; only `updateHeader()`, `readerCurrentFileChanged`, and off-screen work should be coalesced.
