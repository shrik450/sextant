# Sextant performance plan (approved 2026-11-06)

Goal, in the user's words: "if you're working on a large project with agents this will let you fly through it, perfectly, fast, native, low memory." No wasted work; everything to a very solid level of performance, with reasonable tradeoffs where going further gets overly complex or hurts the experience.

Sources: scratch/perf/audit1/efficiency.md, scratch/perf/audit1/architecture.md, scratch/perf/audit2/audit.md (scripts, results and fixtures under scratch/perf/audit2/), scratch/review/astra.md, scratch/review/argon.md.

## Decisions
- No custom fsmonitor hook, no untrackedCache, nothing that writes the user's .git/index. Use literal pathspecs (`--literal-pathspecs` or `:(literal)`), `GIT_OPTIONAL_LOCKS=0`, and `-c diff.autoRefreshIndex=false` on diffs.
- Keep TextKit 1. No custom NSTextStorage, no CTLine renderer, no Fenwick tree unless a later step proves the need. Full reloads swap in a fresh NSTextStorage (`layoutManager.replaceTextStorage`).
- Keep hunk DiffLines for hunks-only display; load whole blobs lazily (opened, unfolded, near the viewport). Never load every blob for All Changes.
- No incremental reparsing (`ts_tree_edit`); agents rewrite files.
- Definitions persist in SQLite (system libsqlite3), incrementally.
- Large input: syntax analysis off above ~2 MB per side or a line over ~20,000 UTF-16 units (plain text, with a note). Above a much higher limit (~50 MB or ~1M lines), a clearly marked bounded preview with Open in Editor, never a silent truncation. Admission limits apply to blob bytes, line count, line width, patch/output bytes, query captures and concurrent work, everywhere (reading, overview, neighbours, Peek, indexing, grep).
- Renames: path-scoped diffs only for plain modifications at first; any add/delete/rename/index/ref ambiguity gets a full structural comparison.
- One refresh in flight per worktree, with an accumulated dirty set; supersede and cancel obsolete work (including git processes and parses) unless another consumer still needs it.
- No release until the user says so.

## Known findings (verified unless marked)
Bugs on main:
- Row-view leak: rowViewForItem returns look.makeRowView() every time (Navigator.swift:603, :707, Inspector.swift:343); Inspector.merge mutates children before removeItems, without begin/endUpdates. ~30 MB/min growth.
- identifiers(in:tokens:) (Reading.swift:19) is O(identifiers x skipped tokens) and builds CharacterSet.alphanumerics per UTF-16 unit; runs on main when the caret lands: 384 s hang on a minified file. CodeView.identifier(at:) has the same CharacterSet cost.
- Every path ending .lock is ignored by the refresh filter (RepoWindowController.swift ~848), including tracked Cargo.lock/flake.lock.
- ContentAnalysis.saveSoon is dropped unless load() ran, and load() runs only from definitions(of:) (Go to Anything/lookups), so reading-only sessions never save definitions; once loaded, each analysis rewrites the whole JSON.
- Worktree hash-then-read race can cache one content's definitions under another oid; transient read failures are cached as empty definitions.
- SwiftTreeSitter treats #lua-match? as generic (always true): Zig highlights affected.
- Repository status failure becomes "clean" (Repository.swift ~150).
- Shared searchGeneration lets Peek/Jump drop a running Find in Files.
- Patch lines keep CR (Parse.swift:202) while splitLines drops it.
- Untracked files are hashed and read whole during every diff (Git.swift ~186-199).
- Hidden worktrees aren't watched; FileWatcher drops FSEvents flags and IDs, ignores start failure, and roots are canonicalised differently from Repository's.
- Newline paths break hashObjects' line input; parseGrepZ splits on LF before NUL.
Waste:
- Every relevant event: refs + ahead-behind for every branch, status in every worktree, re-resolution, whole-tree diff with an mtime retry loop (up to 4x), untracked scan, full listing with a stat per path, localizedStandardCompare sort on main, navigator rebuild. Trailing 150 ms debounce never fires under sustained writes (22 s stale). Our own git diff rewrites .git/index.
- prepareNeighbors starts 3 uncancelled whole-file analyses per step (i+1, i-1, i+2), including pathological neighbours (the 7.7 GB peak).
- Analysis: no size cap, no cancellation; SwiftTreeSitter allocates per capture (components(separatedBy:) on capture names ~9.5M times on a 10 MB file); names parse a second time; tags-only indexing bypasses running-task sharing.
- Go to Anything re-ranks all candidates per keystroke (1.6-2 s at 1.5M), 760 MB; definitions JSON rewritten whole; one serial cat-file.
- Overview: setAttributedString replace is quadratic in attribute runs (2.9-3.7 s at 10k files); review toggles/notes/zoom re-render everything; up to 185 scroll notifications per reload; analyzeShownFiles walks every file; PaneHeader reduces all files; Inspector builds/follows every entry; drawUses lays out every match; markUses scans every row on main.
- Navigator rebuilds a tree of every path on main (593 ms per mark-reviewed at 300k files).
- ReviewStore/Notes: O(read x files) filtering and pretty-printed whole rewrites on main.
- Git.run parks 2-3 threads per process; ObjectReader never closed, keyed per root, copies through [UInt8].
- Glass per-frame: recursive material search in GutterScrollView.tile, symbol image per drawPill, defaults signature per didChange. Theme watcher can watch $HOME recursively.
- Lookups re-grep every time; no name->location index for definition-only lookups.
- Commit stepping re-resolves and re-reads immutable history.

## Steps (serial: one agent at a time on branch `perf`, fresh session per step)
0. Guardrails: benchmark suite from audit 2's scripts (agents, large repos, pathological, overview edits, Go to Anything, soak with view-object counts, idle, untracked burst, renames), committed and rerunnable; fix the stall probe to report in-flight stalls; record budgets and a baseline.
1. The confirmed bugs above (each with a test).
2. Limits and lifetimes: admission limits, cancellable parsing (parser timeout/cancellation flag), bounded and cancelled neighbour preparation, lazy untracked reads, bounded grep results, ObjectReader lifetime, byte-bounded O(1) LRU.
3. Cheap UI fast paths: replaceTextStorage on reload, review toggle without text replacement, persistent navigator nodes with reloadItem, coalesced scroll notifications, overview work bounded by what's visible, review/notes persistence off main, off-main byte-wise sorts, glass per-frame waste, theme watcher.
4. Refresh coordinator: one in flight per worktree, FSEvents flags/IDs and recovery rescans, canonical roots, classification (refs/HEAD, index of W, file in W, ignored via batched check-ignore), no self index writes, lazy cached ahead-behind, Git.run without parked threads. Still full git answers.
5. Change fast paths: status on event paths first, path-scoped diffs for plain modifications only, cached commit lists/tree listings, differential tests against git after adversarial traces (rebases, renames, dropped events, concurrent index writers).
6. Content: one parse with demanded outputs, C API with predicate parity (fast paths for common regexes), names inside ContentAnalysis via one cursor walk, the store hashing the exact bytes it analyses.
7. Search: candidate arena, top-k, narrowing over all prior matches, cancellation, SQLite definitions, name->location index, lookup caches, measured reader pool.
8. Per-block overview text edits, only if step 3 misses its budgets.

## Verified findings from Argon's scoped audits
Full reports: scratch/review/argon-sections/<section>.md (benchmarks under <section>/). Only what was checked independently is listed here; the rest of each report is leads, not facts.

git (scratch/review/argon-sections/git.md), checked against code and real git:
- Merge conflicts: `git diff --raw -p` emits a combined `::` raw header (3 modes, 3 oids, status at index 6) and no patch for the unmerged path; parseRawMeta misreads it and parseRawPatchZ hands the next file's patch to it, shifting every later file's diff. (Step 1)
- `git hash-object --stdin-paths` exits 128 on a dangling symlink or a symlink to a directory (also, per Argon, gitlinks and untracked nested repos), failing the whole diff. Symlinks must hash their link text in-process; never pass gitlinks or directories. (Step 1)
- Repository.open (Repository.swift ~247) runs oldLines + wholeFile on the first diff even when it's an added file; oldLines falls back to the new side, so the whole file appears twice. (Step 1)
- Git.run has no cancellation handler (Git.swift:27): cancelled tasks leave git running and the awaiting scope blocked until it exits; stdout is buffered without a limit. (Steps 2, 4)
- readWorktreeFile checks size with lstat then reads through the symlink, bypassing the 4 MB cap, and returns target contents rather than git's link-text blob. (Steps 1, 2)
- wordRanges computes word diffs for every changed pair in the file on the main thread on first colour, and again after setWhole; wordDiff doesn't trim common prefix/suffix before its n*m guard. (Step 3)
Unverified leads in git.md worth checking during the steps: ObjectReader fd leak via dup, 3x blob copies and missing size admission; parseLog's Character splitting (~18x slower than bytes) and CRLF summary bug; parseBranches dropping names ending /HEAD; Resolver falling back silently past the 1,000-commit window; parseBlamePorcelain allocation; defaultBranch's sequential processes.

repo (scratch/review/argon-sections/repo.md), checked against code and Foundation docs:
- afterFrame(waitingForFile: true) (RepoWindowController.swift:588) re-adds a 0-interval Timer on every run-loop pass while a file loads: a main-thread busy spin, with `busy` dipping each spin (premature idle waiters). Keep the work pending and run it when the load finishes. (Step 1)
- resolvingSymlinksInPath() strips /private (documented), while FSEvents and git use realpath: repositories under /tmp, /var or a symlinked path get no uncommitted/conflict lookups (keyed by git's realpath) and refresh on their own .git/sextant writes. Canonicalise every root with realpath(3). Also filter commonDir/worktrees/<id>/logs. (Steps 1, 4)
- setWhole mutates a shared FileState's lines in place (Document.swift:117); per Argon, an overview pane sharing the session keeps hunk row indices into the now-whole lines (wrong text, colours, line numbers, note anchors), and `unfolded` leaks across panes. Mutation verified; the visible corruption needs a GUI repro before fixing. Hunk lines and whole lines should be separate, view state per pane. (Steps 1, 3)
Unverified leads in repo.md: updateTitle rebuilding the whole branch menu per file boundary (23.7 ms at 10k branches); SubjectPicker.rebuild cost and remote-branch suppression; O(C x P) scans in toggleReviewed/validateMenuItem; refresh reloading unchanged open files (losing selection, blame, uses); stale saved base branches; tasks/timers alive after window close; RevisionSheet re-entry.

document (scratch/review/argon-sections/document.md), checked against code:
- Pure renames and mode changes have no hunks, and FileState.init (Document.swift:61) marks "no hunks" as whole with zero lines, so their contents never load: they can't be opened, read or jumped into. (Step 1e)
- changeKey (Reading.swift:118) hashes file, kind and text with no position, so identical change runs in one file share a read key: reading one reads all, and can mark the file reviewed early. Changing the key changes stored review state; decide the migration (hard cutover per the user's rules) in the fix. (Step 1e)
Unverified leads in document.md (check in step 1e): Outline barrier/collision bugs; deleted lines' newNo == 0 breaking definition stepping (685 ms stall), breadcrumbs; side-by-side desync after multi-line notes; fileTree hiding unchanged files in merged folders; reference dropping deleted lines with a context line selected and lineNumber(at:) crashing on empty files; toggleShowAll clobbering the caret; prepareWhole blocking open() on neighbour parses; reviewsChanged recolouring every file; non-BMP identifiers; layoutRows O(F x notes x L); reviewKey String per access; up to 6 parses for one file opened with the caret on a name; jump labels capped at 676; isTwoSided false for one-sided modifications.

analysis (scratch/review/argon-sections/analysis.md), checked against code:
- The tags query runs every @reference.* pattern, and both consumers (ContentAnalysis.swift:245, Jump.swift:88) keep only definitions; Argon measures references at 50-80% of tag-query time. Drop reference patterns from the definitions pass. (Step 6)
- Names.swift:300 drops a candidate whose named node type equals its spelling, meant for keyword-like nodes (C++ `auto`), but it also drops real variables named like the grammar's identifier node type (`name`, `word`, `identifier`, ...). (Step 1e)
- ContentAnalysis.prune(keeping:) wipes every saved definition when `current` is empty (count > 0 * 3). (Step 1c)
Unverified leads in analysis.md: identifiers inside string interpolation skipped; SwiftTreeSitter query execution plus the names reparse at 82-85% of per-file analysis; broken locals.scm handling in Just, Haskell, OCaml, Julia, Scala, Svelte; unhandled predicates (#is-not? local, #has-ancestor?) and missing capturesAgree in tokens(); missing/broken definition rules in Swift, TS/TSX, Go, Dart, Zig tags and Swift computed-property locals in the outline; lookUp failing on $foo, make-point, swap!; full ls-tree per commit lookup; rankJump 4.27 s per key with uncancelled detached tasks and a greedy prefix bug; RecentlyUsed O(N) eviction; SyntaxRuntime.load hashing 49.8 MB at launch; Peek's main-thread split/hash, no size guard, stale-anchor popovers.

reader (scratch/review/argon-sections/reader.md), checked against code:
- rect(ofRow:) (CodeView.swift:416) calls ensureLayout from glyph 0 up to the row, defeating non-contiguous layout; the caret, gutter and pill hover and clicks use it, so their cost grows with the row's position (Argon: 684 ms at 100k rows). Query the row's own fragment instead. (Step 3)
- analyzeShownFiles (Reader.swift:197) runs on the main actor and rescans every shown file per step via nextToAnalyze, plus files.firstIndex per step: quadratic in files (Argon: 6.1 s at 10k). Order by what's visible, and keep the cursor. (Step 3)
Doubtful, needs an in-app repro before any change: Argon's Finding 1, that drawBackground painting row tints after super erases word-diff/selection/find highlights; TextKit 1 draws temporary-attribute backgrounds after drawBackground(in:).
Unverified leads in reader.md: per-row attribute dictionaries and paragraph styles in render(), displayText 68x slower with CR; refreshReadState recolouring every file; color(row:) never marking rows coloured while tokens are nil (word diffs and makeReadable rerun every scroll); row(for:in:) auto-unfolding and reloading twice in toggleShowAll; visibleRows appending the extra line fragment; caretRect on the wrong line when wrapping; identifier(at:) crossing rows; empty-line selection trapping V mode; U+2028/2029/0085 and notes desyncing side by side; show() laying out at the old offset, present() querying layout 3x per open; linear rows scans and numberColumnWidth reductions.

sidebars (scratch/review/argon-sections/sidebars.md), checked against code:
- The Find File filter runs rankFuzzy over every path on the main actor per keystroke and per review toggle (Navigator.swift:438; Argon: 1,086 ms at 300k files). Rank off main with the step 7 candidate table and cancellation. (Steps 3, 7)
Plausible, needs a test: Inspector.follow inserts row(forItem:) results (-1 for hidden items) into an IndexSet and relies on remove(-1) (Inspector.swift ~291-316); Argon says it breaks selection when a section is folded.
Unverified leads in sidebars.md: search result rows not capping long match lines (240 ms per row on a minified line) and splitting surrogate pairs; Inspector.rebuild O(R x S) re-run on every caret move with blame on; follow() missing the enclosing definition on deleted lines; Command-click not opening beside when a row is selected; selectFocus failing in collapsed folders; O(C x P) Array.contains in toggleReviewed/validateMenuItem; crumbClicked scanning all paths twice; CommitCell formatting dates and reviewKeys per reviewsChanged; PaneHeader/ChangeCounter work per scroll; NotesPane focus stealing and reload churn; Inspector pruned/entry cubic in depth; expand/collapse churn; JumpPanel stale results and post-dismiss ranking; SF Symbol images rebuilt per configure/draw.

From step 1b (973c275..2ee9ec7), for later steps:
- caret_word now measures real moves (max ~12-14 ms) and misses its 8.3 ms budget. (Step 3)
- Patch lines drop CR, so a change only in line endings shows identical -/+ lines; say so in the reader. (Step 1e)
- Paths are decoded as UTF-8 lossily; a non-UTF-8 name now drops out of worktree diffs. Paths should be bytes end to end. (Steps 4, 5)
- Unmerged files in the unstaged view show the worktree against our side (`--ours`), not a combined patch.

chrome (scratch/review/argon-sections/chrome.md), checked against code:
- updateTitle() runs on every Overview file boundary (readerCurrentFileChanged, RepoWindowController.swift:1092) and twice per open, and each run rebuilds the base pop-up's whole NSMenu (BaseChoices.fill, ReviewSummary.swift:28; Argon: 21 ms at 10k branches), replacing it even while it's open; the usual base also appears twice (usual plus local). Update only on change; fill the branch list lazily in menuNeedsUpdate. (Step 3)
- Nothing cancels a dropped Session's indexTask (it captures the session weakly and keeps indexing), and discard(_:) (RepoWindowController.swift:791) leaves a closed pane's Reader.analysis and pending loads running, retaining the Reader. Session.explored is never evicted. (Step 2)
- Appearance.lastSignature starts empty, so the first UserDefaults write of any key posts Appearance.didChange: every Reader reloads and the window redraws right after the first open. Font and tab changes also redraw all chrome and reload hidden panes. (Step 3)
- NSImage.monochromeSymbol (Theme.swift:434) builds a new drawing-handler image per call (cells configure, ProgressPie draws); theme(for:) and Style.current re-read defaults per call. (Step 3)
- Settings' monospaced font list matches "code" in "Arial Unicode MS" (a proportional font) and loads every family on main at first open. (Step 1c or 3, small)
Unverified leads in chrome.md: peeking pane headers clipping titles and controls (needs a look in the GUI); slide animations not animating on branch() and double-dimming; stripOffset drift on resize with 3+ panes; user themes loading in filename rather than base order; the theme watcher never stopping and firing on non-JSON files; look changes mutating open windows' themes; dead chevron click zone; status bar double-click zooming the window.

app (scratch/review/argon-sections/app.md), checked against code:
- gitPath (main.swift:12) is a lazy var read on main in openRepo; it reads the global loginShellPath, which a background queue is still initialising (fish -l -c /usr/bin/env), so main waits on swift_once for the login shell. The 5 s terminate doesn't bound readDataToEndOfFile when a grandchild keeps the pipe, and taking the last PATH= line of env output can be fooled by a multi-line variable. Resolve git off main, run printenv PATH (or env -0) in its own process group, and close the pipe on timeout. (Step 1c/2)
- The sextant CLI waits for NSWorkspace.open with RunLoop.run(until:) on a run loop with no sources, which returns at once: a 100% CPU spin for the whole open. Wait on the semaphore. (Step 1, small)
- validateMenuItem (WindowActions.swift:744) disables every bare-key command while an editable text view is first responder, which also drops them from Go to Anything opened from a filter field; it rebuilds per-item state (commitRows, notes, keyedRuns) for each of ~60 items. (Steps 1e, 3)
- Every window uses frame autosave name "SextantWindow": the second window's setFrameAutosaveName fails (AppKit allows one window per name), so it opens exactly on top of the first and its frame is never saved. (Step 1, small)
Plausible, needs a test: showDefinitionsMenu's glyph lookup at the end of the text (Argon says NSRangeException); openRepo racing start() so a second open sees empty branches and is then clobbered by the first open's openWork.
Unverified leads in app.md: CLI misreading branch names that match a folder, rejecting file paths and --staged/--cached (link SextantCore's parseRevisionSpec); nearest() counting the file name as a directory and re-splitting per comparison; stale-pane popups after lookUp and showFileHistory, and findReferences stuck on "Searching…" on error; card() rebuilt per caret move with blame on; a hidden second CodeView per pane in unified mode; automation harness: sendKey("cmd++"), menu shortcuts in --background, static idleWaiters, waitIdle ignoring reader.isSettled (relevant to the perf suite's accuracy).

From step 1c (d289300..111b2a8): roots are CanonicalPath (realpath) everywhere; saved-base keys use the canonical commonDir (hard cutover); a failed status shows "Status unavailable". Still open: #is-not? local unhandled (every Ruby identifier coloured as a method) for step 6; lost definition saves for step 7; predicate checks cost +7% on a 720 KB Zig parse.

From step 1d (ca94ad1..97bd80f): FileState (shared) holds the diff, review state, and immutable FileTexts (hunks; whole once read); ShownFile (Reader.files) is per pane (text shown, unfolds). Every pane picks wholeOrHunks at layout, as main did. Scenes in Tests/scenes.sh (47 checks). Step 3: load visible files whole for Show Unchanged Lines in the overview; overview edits still ~2.95 s.

From step 1e (a8c3c7e..3dbb389): run read keys = line hash + occurrence; reads kept per starting file and pruned per review (read.json 59 MB -> 2.9 MB at 10k files x 20 base moves); keyword nodes from grammar.json; line-ending notices. Measured for later: refreshReadState 28-47 ms per toggle at 10k files, then the overview reload 2.71 s (step 3's real target); 4 parses per direct open, 7 from All Changes (step 6); reviewKey ~0.7 us per visible row; layoutRows notes cost negligible. UX change: merged folder rows get a pill revealing their unchanged files (was hidden until Show All).

From step 1f (b959c38..2208911): login shell resolved off main in its own process group; CLI shares parseRevisionSpec (binary 103 KB -> 2.4 MB from linking SextantCore; a core target without tree-sitter would avoid it); per-repo frame autosave; bare-key guard only for the key matched; harness waits for colours with per-window waiters; reviewed.json owned and pruned (32.5 MB -> 1.9 MB). Did not hold: CLI run-loop spin, NSRangeException at end of text. Scenes 88/88, tests 182.

From step 2a (6ac0f0f..10f9999): Git.run in suspended process groups, cancel SIGTERM->SIGKILL, per-caller limits, no parked threads (90 -> 0 at 64 gits); one cat-file per repository (Git.forCheckout), idle end 20 s; one neighbour, 1 MB budget, SharedWork; MemoryCache 64 MB byte LRU (500-file Linux read 312 -> 142 MB). Release-only Swift 6.3.3 miscompile in refreshStatus's task group fixed (6c5533a); release test runs now in the routine. Soak/linux memory is AppKit and transient parse memory (steps 3, 6).
