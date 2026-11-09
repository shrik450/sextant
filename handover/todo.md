# Todo

## Now (2026-11-07): 0.3.0 released (a31ff68 = perf cba3ba3 + version); perf continues on `perf`

- Plan: scratch/perf/plan.md (decisions, known findings, steps 0-8). Serial: one Claude agent at
  a time on branch `perf` (worktree ~/.herdr/worktrees/review-ui/perf, w2Z), a fresh session per
  step; briefs in scratch/perf/steps/ (rules.txt + stepN.txt), notes in steps/N.md.
  Step 0 done (c66a6bf..7fc00ee). Step 1 split into 1a-1e (scratch/perf/steps/order.txt): step 1 done (1a-1f); 2a done; 2b partial, PAUSED on weekly usage (11%): resume from steps/2b.md.
- Large files first-class, not capped (user, 2026-11-07): the 2b limits (plain >2 MB or a >20k
  line, preview >500k lines, 256 MB patch fails) are provisional. The limits come from our design,
  not git/tree-sitter/macOS: ~200 B per line (DiffLine + String), eager whole-file analysis with
  every token materialised (names reparse, quadratic predicate offsets), the whole file in one
  TextKit storage (a 10 MB line laid out as one paragraph), whole diffs materialised. Direction:
  content as one buffer + line index (diff lines as ranges); one background cancellable parse,
  highlight/names queries over the visible byte range only, plain text first then colour in;
  outline/definitions streamed; virtualised display (visible window in the text storage, height
  from line count, long lines in display chunks); huge diffs as a file list first, patches per
  file on demand (step 5). Admission stays as the boundary, but plain text becomes "while parsing
  or over time budget" and preview only for files that don't fit memory (mmap). Before step 3:
  spike measuring (1) tree-sitter parse time and tree memory on million.c and minified.js via the
  C API, (2) TextKit 1 window virtualisation at 1M lines (smooth scroll, selection/find/caret
  across the window edge), (3) how much code depends on DiffLine.text being a String. Then fold
  into steps 3 and 6 (revisits "keep TextKit 1, no custom text storage" for this case only).
- Argon: scoped audits, one section at a time (scratch/review/argon-sections/: sections.txt,
  brief.txt, queue.sh in the background, queue.log). Outputs <id>.md; I verify each one's claims
  before they feed the plan. Order: git, repo, document, analysis, reader, sidebars, chrome, app.
- Audits and reviews: scratch/perf/audit1, audit2 (with fixtures), scratch/review/astra.md, argon.md.

## Earlier state

- Both perf audits are in: perf-audit/scratch/audit.md (independent, blind) and
  audit-fixes/scratch/efficiency.md. Comparison, design and build plan were given to the user
  (step 0 guardrails + memory attribution; Wave 1: A content bounds/one parse/C API,
  B repository model, C Go to Anything table; Wave 2: review model, row blocks, navigator,
  glass per-frame waste). Waiting on three decisions: go with the plan; parallelism (3 agents
  or one at a time); plain-text threshold for huge files (~2 MB or a ~20k-unit line).
- Verified in code: trailing debounce never fires under sustained events; no size cap in
  FileState.analyze; diff retry loop; ObjectReader kept for app lifetime; theme watcher
  watches nearest existing ancestor recursively; ignored paths count as relevant; git diff
  rewrites .git/index with GIT_OPTIONAL_LOCKS=0; localizedStandardCompare sort on main.
  To verify: whether -c core.untrackedCache=true writes the index; "quadratic" highlights.
- Crash fix (layout-loop branch, occurrences worktree): interrupted right after resuming;
  check its working tree before continuing.

2026-11-06. Main is 8671a05 (classic landed). Last release 0.2.2 (e7fa14e).

## In flight (herdr agents, each in its own worktree)

- Occurrence highlighting merged (d846eda): scoped in 14 languages with our locals queries,
  6 upstream, spelling elsewhere; * Highlight Uses kept; no markers for occurrences in folds.
- Layout-loop crash, PAUSED by the user (usage goes to the audit): glass crashes with an
  AppKit layout loop opening src/terminal/page.zig via Go to Anything in ghostty
  a573781c6^..a573781c6; main has it too. Must be fixed before 0.3. Uncommitted
  investigation in the occurrences worktree on branch layout-loop (Inspector.swift and
  main.swift edits, a ZZLayoutTrace.swift tracer, scratch notes); resume from there.
  Fix found and confirmed: backingAlignedRect(..., .alignAllEdgesOutward) on the inspector
  row's title frame (Inspector.swift:577); NSGlassEffectView resizes text fields at
  fractional scroll offsets. Left: same for InspectorSectionCell, TreeCell, Go to Anything
  rows; fixture regression scene; remove tracer. Resume AFTER the perf audit (user's call).
- Efficiency report done (audit-fixes/scratch/efficiency.md, sextant-audit idle). I verified
  three claims (ignored paths count as relevant; git diff rewrites .git/index even with
  GIT_OPTIONAL_LOCKS=0; localizedStandardCompare sort on main). Not the final word.
- The goal (user's words): "if you're working on a large project with agents this will let
  you fly through it, perfectly, fast, native, low memory"; no wasted work, reasonable
  tradeoffs. Plan: (1) independent audit, (3) verify findings, (4) build. No competitor
  benchmark.
- sextant-perf (perf-audit worktree, w2Y): the independent audit, blind to both earlier
  reports, covering agent churn, many worktrees, large repos, pathological input, memory,
  idle, launch, rendering, threads. Report to scratch/audit.md plus rerunnable scripts.
  Brief in scratch/msgs/audit3.txt. Then I compare the two reports, verify what drives work,
  and plan the build.
- Classic landed (46af291..8671a05), including a97fb0d: Undo, Redo, Cut, Paste in the Edit
  menu, which 0.2.2 lacks (Command-V can't paste into notes).
- Release: cut 0.3.0 once occurrences and the audit's chosen work have landed (user's call).
  Open: whether default themes follow each window's look (now app-wide).
  Both classic worktrees removed; their shots are in scratch/looks/classic-port and
  scratch/looks/classic-original (with look-classic's uncommitted work as a diff and tarball).
- Merged and cleaned up: definition index (ffbce08) and tags queries (6734e9f). Follow-ups:
  saved definitions are pruned only when Go to Anything indexes a snapshot; nobody has looked
  at the new definition icons in the GUI.

## Decide first thing

- The architecture report traces the old bug list to three missing owners: a snapshot/Tree
  type (listing, reading, name resolution), a shared repository/session model (the window
  controller runs every session's life cycle), and a content-keyed (oid, grammar, query)
  line and analysis cache. Decide whether defindex aims at that cache and whether the audit
  fixes become the Tree type, instead of patching each symptom. Review the report with the
  user before any audit fixes.
- New finding in the report: a shared searchGeneration counter lets Peek or Jump to
  Definition drop a running Find in Files.

## Perf regression: fixed in 0.2.2

- The changed-word contrast search (f7a464c) ran on every word drawn: "Next file, sidebars
  too" took 97.6 ms. eaf74a2 memoises it per colour pair: 10.5 ms (budget 16). 0.2.1 never
  published (GitHub 500 at release creation); its tag stays, unused.
- Still to do: measure dimming on and off.

## Done today

- Glass look follow-ups: palette in Primer mid-tones, card rim and shadow, frost wash,
  gutter pocket fix, changed-word contrast (every theme reaches AA on highlights).
- Zoom Pane (⇧⌘↩), header buttons always shown with zoom, Copy Notes (⇧⌘C), Copy Symbol with
  Reference (⌘Y).

## Housekeeping

- Old Revue test process (PID 31863) from the removed glass worktree: the user quits it.
- ~/Developer/nix: the Sextant cask and `sxt` alias are still uncommitted.
- Optional: tune the icon for macOS 27 in Icon Composer 2 (needs developer sign-in).

## Punted

- Remappable keys (keymap file in SextantCore, menus and tooltips from it).

## Later

- Build with the macOS 27 SDK once Swift 6.4 reaches nixpkgs-unstable: bump the flake lock
  and move `apple-sdk_27` into `buildInputs` for both the dev shell and the package.

## After 0.3.0

- Flaky: SyntaxTests.parsingInABackgroundTaskDoesNotKeepMemory measures the whole process heap, so
  parallel tests inflate it (failed once in release, 5/5 alone). Measure in isolation or serialise.
- paneclose scene: 390 CPU-ms after closing a pane mid-analysis (expects <200): cancellation
  latency, part of 2b's remainder.
- Diffs over Git.Limit.patch (256 MB) fail the whole review; revisit with the large-files work.
