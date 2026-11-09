# Sextant performance audit

Auditor: sextant-perf. Build: release, commit `d846eda`, bundle ID
`com.shrikanthup.Sextant.sextant-perf`. Machine: M5 Pro, 18 cores, macOS 26.6.
Load average during runs: 1.5 to 7 (other agents were working), recorded in every
`results/*/meta.txt`. Numbers are medians unless marked; "p90" and "max" are
over the repetitions in one run. Measurement method and caveats are in section 5,
and section 6 lists the scripts.

The claim under test:

> If you're working on a large project with agents, Sextant lets you fly
> through it: perfectly, fast, native, low memory. It is cycle-efficient: no
> wasted work, everything done to a very solid level of performance, with
> reasonable tradeoffs where going further would make it overly complex or hurt
> the user experience.

## Verdict

For reading a review of ordinary size, the claim mostly holds. In the ghostty
review (82 files), moving between files takes one frame (median 6.8 ms) and is
fully coloured in 25 ms. Scrolling costs 0.3 ms a step. The idle app is close
to silent, with about 2 wake-ups a second and about 1.6 ms of CPU a second. A
warm launch shows content about 300 ms after the process starts. Nothing leaks.
The footprint does grow, though: from 209 to 423 MB over 7 minutes of
navigation beside an agent, not yet attributed.

The claim fails in exactly the cases it names: agents, and large projects.

1. **Every filesystem event redoes the whole repository.** Each event runs
   12 git processes, plus one more for each extra worktree. On a 300,000-file
   checkout, one edit costs **9.5 CPU-seconds**: 1.8 s in the app and 7.7 s in
   git. A Linux checkout costs **7.8 s of git CPU per refresh**. Build output
   that git ignores still triggers the full refresh. While an agent writes
   continuously, the refresh debounce never fires: the screen stayed stale for
   **22 s** of sustained writes.
2. **One large generated file can take the machine down.** A 1 MB line or a
   1,000,000-line file pushes the app to **7.7–7.9 GB** and 50 CPU-seconds. A
   10 MB minified bundle keeps a core busy for **more than 6 minutes** and never
   finishes highlighting. Nothing caps the work, and nothing cancels it.
3. **Go to Anything doesn't scale.** At Linux size, with 97k files and 1.44M
   definitions, **each keystroke costs 1.6–2.0 CPU-seconds**. The index adds
   **760 MB** and rewrites a 64 MB JSON file.
4. **Small changes rebuild whole structures on the main thread.** In a 10,000-file
   overview, marking one file reviewed, zooming, or adding a note freezes the
   window for **2.9–3.7 s**. In a 300,000-file repository, marking a file reviewed
   freezes it for **593–697 ms**, because the navigator rebuilds its tree of
   every path.
5. **Opening a review waits for ahead-behind counts for every branch.** On the
   shallow Linux clone, content takes **8.8 s** to appear. The same 6.5 s
   for-each-ref runs again on every refresh.

None of these is a hard problem. Most of the waste comes from one design
choice: change detection is a single boolean ("something changed, redo it
all"), when the system already has the information to do only what changed.
Section 3 describes the design that fixes this. A good part of the current code
already fits it.

## 1. Scenarios

### 1.1 Agents at work

**Setup.** `work` is a clone of the ghostty showcase on branch `agent`, 56
commits ahead of `origin/main`, with uncommitted edits. A driver plays the
agent. It rewrites 100 files three times in bursts, then rewrites 20 files a
second for 15 s, then creates, deletes and renames files. Next it writes 2,000
ignored files to `zig-out/`. Finally it runs commit, checkout, stash, rebase and
`worktree add`. After each phase it records the true diff and checks the app's
state dumps against it every 250 ms.

**Correctness.** Every phase converged to the right totals and paths, so the
screen is eventually exactly right.

**Time until the screen is right** (`agents1`, measured from the end of each phase):

| Phase | Converged after | Git processes | Git CPU | App CPU |
|---|---|---|---|---|
| Burst of 100 rewrites (×3) | 955–1070 ms | 24–26 | 1.47–1.57 s | 0.49–1.13 s |
| Sustained, 20 writes/s for 15 s | 1014 ms after the writes stopped, **no update for the 22 s while they ran** | 24 | 1.54 s | 1.00 s |
| Create, delete and rename | 1082 ms | 24 | 1.58 s | 0.60 s |
| 2,000 ignored build files | nothing to show | **23** | **1.55 s** | 0.71 s |
| Commit | 497 ms | 22 | 1.03 s | 0.41 s |
| Checkout | 545 ms | 33 | 0.85 s | 0.81 s |
| Stash | 562 ms | 33 | 0.88 s | 0.65 s |
| Rebase | 583 ms | 23 | 0.54 s | 0.51 s |
| Worktree add | 179 ms | 33 | 1.11 s | 0.36 s |

The whole run took 185 s: 173 git processes, 7.9 s of git CPU, 5.6 s of app
CPU, and a footprint peak of 218 MB.

**Where the time goes.** Every relevant FSEvents batch goes through the same pipeline:

1. `filesystemChanged` (`RepoWindowController.swift:844`) reduces the changed
   paths to one boolean. It drops only `.git/objects`, `sextant`, `lfs`, `logs`
   and `*.lock`. Paths that git ignores count as relevant.
2. `refresh()` (`RepoWindowController.swift:854`) is a trailing debounce: it
   cancels the previous task and sleeps 150 ms. If writes keep arriving less
   than 150 ms apart, it never fires. That is the 22 s blackout.
3. `Repository.refresh()` (`Repository.swift:74`) re-reads every ref. That runs
   `symbolic-ref`, the stash reflog, `worktree list`, and `for-each-ref` with
   `%(ahead-behind:base)` for every branch (`Refs.swift:76`). It then runs
   `git status --untracked-files=all` in every worktree (`Repository.swift:118`,
   `:150`).
4. Each session that includes the index reloads from scratch. Resolving runs
   `rev-parse`, `merge-base`, and `log base..head -n 1000 --raw -M`
   (`Review.swift:160`, `:173`). The diff runs `diff -p -M` over the whole
   worktree, `ls-files --others`, and `hash-object` for every untracked file.
   If any changed file's mtime is newer than when the diff started, the diff is
   repeated, up to 4 times (`Git.swift:169`), which is likely while an agent is
   still writing.
5. `apply` (`RepoWindowController.swift:385`) compares the new diffs with the
   old ones field by field and stops if they are equal. If they differ, it runs
   `loadSnapshotFiles`. That lists every file in the snapshot, does two
   syscalls per file (`Explore.swift:63`), and sorts the list with
   `localizedStandardCompare` on the main thread
   (`RepoWindowController.swift:451`). It then rebuilds the navigator's tree
   of every path on the main thread (`Navigator.swift:434`).

The floor for "an agent rewrote some files" is the FSEvents latency (100 ms),
plus a diff of only those paths (a few ms), plus applying them to the screen
(one frame). That totals about 120–250 ms, with 1–3 git processes per batch and
none for ignored paths. Today it takes 0.5–1.1 s and 22–33 processes. It costs
the same whether one file changed or 400, and whether the file was tracked or
ignored.

### 1.2 Several worktrees

There is one window per repository. Opening another worktree of the same
repository reviews it in the focused pane of that window (`main.swift:80`). I
opened `work` and four linked worktrees in five panes (`worktrees`). A driver
then appended to and staged one tracked file in each worktree once a second
for 30 s:

| | Wall | App CPU | Git CPU | Git processes | Footprint |
|---|---|---|---|---|---|
| One pane, idle | 8.4 s | 137 ms | 13 ms | 2 | 98 MB |
| Five panes, idle | 10.5 s | 67 ms | 0 | 0 | 161 MB |
| Five panes, five agents staging | 30.2 s | 3.67 s | **11.75 s** | **412** | 115–256 MB |

The run had 21 refreshes in 30 s, with 20 git processes per refresh. Each
refresh ran five `status --untracked-files=all` processes, one per worktree,
whichever worktree changed. Over the 30 s that is half a core, continuously,
and the cost grows with the number of worktrees times the rate of change. There were 31 main-thread waits over 8.3 ms and 11 over 50 ms.

The watcher covers the common git directory and the roots of the worktrees
that panes show (`RepoWindowController.swift:212`). An edit in a linked
worktree that no pane shows doesn't trigger a refresh until something touches
the git directory. Until then, that worktree's uncommitted count in the picker
is stale. This is a small correctness gap in a feature built to show exactly
that count.

Each pane adds about 16 MB (98 → 161 MB for four more panes).

I didn't measure several windows, one per repository (section 5). From the
code, each window has its own `Repository`, FSEvents stream and `cat-file
--batch` process, and the `cat-file` process outlives the window (F10).

### 1.3 Large repositories

**ghostty (`work`, 82-file review).** Opening shows content at 184–330 ms and
settles at 395–1159 ms. One no-op refresh, where nothing relevant changed,
costs 11 git processes, about 550 ms of git CPU and 27 ms of app CPU.

**Linux, shallow clone with 400 commits of history and 97,360 files.** The
review was `HEAD~30..HEAD`: 1,217 files and 91k lines.

* **It takes 8.8 s to show content.** `for-each-ref … %(ahead-behind:origin/HEAD)`
  takes 6.4–6.7 s on this clone. A commit-graph can't be written for a shallow
  repository, so git walks about a million commits. `Repository.open` awaits
  `readRefs` before it resolves the review (`Repository.swift:235`). A deep
  clone with a commit-graph would be much faster, but the cost grows with
  branches × history in any repository with many branches. Section 5 has
  more on this.
* **A refresh of the Linux worktree costs 7.8 s of git CPU** (12 refreshes in
  89 s), mostly ahead-behind and `status`. `status` alone is 0.23 s of wall
  time and 1.14 s of system time.
* Mark File as Reviewed takes 188 ms, and 327 ms in the overview. Overview side
  by side takes 176 ms, Bigger 175 ms, Older Commit about 1 s, and All Commits
  1.24 s. The footprint peaks at 488 MB.

**Synthetic, 300,000 files.** Commit 2 changes 3,000 files, adds 500, deletes
500 and renames 200.

* Opening `HEAD~1..HEAD` shows content at 574 ms and settles at 2.5 s, with
  main-thread stalls of 693 ms and 563 ms. These come from the snapshot sort
  and the navigator tree.
* **Mark File as Reviewed freezes the window for 593 ms**, and for 697 ms in
  the overview.
* **Each edit in the worktree costs 1.8 s of app CPU and 7.7 s of git CPU**,
  with main-thread stalls of about 155 ms and 45 ms (`edits-synth`).
  `sample` attributes 1.2 s of the app CPU to the existence check in
  `Explore.swift:63`. `URL.appendingPathComponent` does an `lstat` for its
  directory hint, and then `fileExists` does a `stat`, for each of 300,000
  files. About 100 ms goes to the navigator's `fileTree` on the main thread,
  and 24 ms to the sort. On the git side, `status --untracked-files=all` takes
  0.9 s of wall time and **10.2 s of system time**. The worktree diff takes
  1.23 s of wall time and 10.15 s of system time. Both stat every file in the
  checkout.
* One no-op refresh of the clean worktree costs 7.2 s of git CPU.
* **The same questions asked of one path cost almost nothing** (best of three,
  with one modified file):

  | Command | Whole tree | One path or its folder |
  |---|---|---|
  | `status --untracked-files=all` | 1,025 ms | 31–32 ms |
  | `diff --raw -p -M` (worktree) | 814 ms | 25 ms |
  | `ls-files --others` | — | 16 ms (folder) |
  | `hash-object` | — | 8 ms |
  | `status` with git's fsmonitor and untracked cache | 214–230 ms | — |
  | worktree diff with git's fsmonitor | 28 ms | — |

  Most of the 25–32 ms is reading the 300,000-entry index. That is the floor
  for an incremental refresh at this size, against 9.5 s today.

### 1.4 Reading and reviewing

Two times are given for each action. "Frame" is the synchronous handling plus
`displayIfNeeded`. "Settled" means the window is no longer busy and the
visible rows are coloured.

| Action | ghostty (82 files) | Linux (1,217 files) | synth (4,200 files) | many (10,000 files) |
|---|---|---|---|---|
| Next File, frame | 6.8 (p90 20, max 36) | 7.4 (p90 27, max 45) | 7.5 | 4.5 |
| Next File, settled | 25 (p90 50) | 29 (p90 65) | 17 | 14 |
| Caret word / line (`w`, `j`) | 0.4–0.6 | 0.3–0.4 | 0.4–0.6 | 0.4–2.3 |
| Scroll a file, per step | 0.3 | 0.3 | 0.2–0.6 | 0.3 |
| Side by Side / Unified | 41 / 26 | 6 / 7 | 42 / 21 | 43 / 27 |
| Mark File as Reviewed | 61 (settled 93) | **188** (229) | **593** (623) | 95 (103) |
| All Changes | 25 | 93 | 73 | **313–360** |
| Overview scroll, per step | 3.6 (p90 6.8, max 9.8) | 6.7 (**p90 9.3–16**) | 3.9 (p90 6.8) | 3.6 (**p90 21–34**) |
| Overview Side by Side | 80 | **176** | 148 | **588** |
| Overview Mark Reviewed | 97 | **327** | **697** | **2,930–3,685** |
| Overview Bigger / Smaller | 50 / 53 | 175 / 153 | 111 / 125 | **2,918–3,930 / 2,906** |
| Older Commit (settled) | 145–245 | **964–1,052** | — | — |
| All Commits (settled) | 240 | **1,238** | — | — |

All times are in milliseconds.

* **Overview edits are O(whole overview) and quadratic in TextKit.** Mark
  reviewed (`reviewsChanged`, `RepoWindowController.swift:874`), notes
  (`notesChanged`, `:881`, which reloads every pane) and font size
  (`Reader.appearanceChanged`, `Reader.swift:116`) each call `Reader.reload`,
  which re-renders every row (`render`, `CodeView.swift:88`). `setContent` then
  calls `textStorage.setAttributedString` (`CodeView.swift:252`). In the
  10,000-file sample, 2,160 of 2,169 ms are in `NSMutableRLEArray
  insertObject:range:` → `memmove`. Building the same overview text in place
  of one file's text (the first All Changes) costs 313 ms. Rebuilding it in
  place of itself (after marking reviewed) costs 2.9 s. Together with the
  `memmove` inside the run insert, that indicates each new attribute run is
  inserted in front of the runs still there, so the cost is old runs × new
  runs.
* **Mark File as Reviewed in a single file** costs 61 ms on ghostty and
  593 ms on synth. The cost scales with the number of files in the snapshot,
  not the review. `refreshReviewState` calls `rebuild()`
  (`Navigator.swift:397`), which runs `fileTree` over every path on the main
  thread (`Navigator.swift:442`). Every filter keystroke in the navigator does
  the same (`Navigator.swift:644`).
* **Stepping commits** (Older Commit, All Commits) re-resolves the review and
  re-lists the snapshot: 26 git processes for four steps. That is 1.9 s of git
  CPU and 2.9 s of app CPU on Linux. The commit list is the same each time.
* **Overview scrolling drops frames** at Linux and 10,000-file scale: p90 is
  9–34 ms against an 8.3 ms frame. I didn't sample the overview scroll on its
  own, so the cause is from code reading. Each scroll event runs `markUses`,
  `colorVisibleRows`, `updateHeader` and `updateChangeCounter`
  (`Reader.scrolled`, `Reader.swift:780`). The caret draw calls
  `rect(ofRow:)`, which ensures layout from the start of the text
  (`CodeView.swift:419`).

**Go to Anything** (`gta-linux`, `gta-synth`):

| | Linux (97k files, 1.44M definitions) | synth (300k files) |
|---|---|---|
| First open: indexing | 21 s wall, **185 s CPU** (9 cores), 76k blobs parsed | 10 s wall, 12 s CPU |
| Footprint, before → after indexing | 145 → **908 MB** | 119 → 436 MB, settling at 335 MB |
| `definitions.json` | **64 MB**, rewritten whole | 22 MB |
| CPU per keystroke | **1.6–2.0 s** (one core, continuously) | 22–25 ms (query `f` matches every name's prefix) |

I didn't measure the second open, which reads the saved 64 MB JSON file
instead of parsing again.

`rankJump` (`Jump.swift:242`) scores every file and every definition on each
keystroke, and `fuzzyScore` (`Jump.swift:13`) allocates heavily per candidate.
It lowercases the query, the name and the candidate separately for each
candidate. In the subsequence branch it lowercases each `Character` into a new
`String` and searches a `String` for the previous character. A query that
matches few names, the usual case, takes that slow branch for nearly every
candidate, about 1.2 µs each. Ranking runs in `Task.detached`
(`JumpActions.swift:66`), so cancelling the panel's task
(`JumpPanel.swift:124`) doesn't stop it. The run typed one key every 1.8 s and
kept one core busy the whole time. From the code, keystrokes typed faster than
that start rankings that pile up on separate cores. The query isn't narrowed between
keystrokes, results aren't selected with a heap, and nothing is precomputed.

**Find References, Peek Definition and Find in Files** (`lookups-linux`, caret
on `do`):

| | Settled | App CPU | Git CPU |
|---|---|---|---|
| Find References, first | 2,255 ms | 1.29 s | 5.55 s |
| Find References, again | 1,416 ms | 0.52 s | 6.84 s |
| Peek Definition (twice) | 1,160 / 1,234 ms | 0.40 s | 6.8–7.1 s |
| Find in Files `kmalloc` | `git grep` takes about 1.0 s | 0.39 s | 7.15 s |

Each lookup runs `git grep` over the whole tree, plus `ls-tree` and parses of
the files that match (`DefinitionIndex.swift:35`). Repeating a lookup redoes
all of it. Peek doesn't use the definition index that Go to Anything built.
`git grep` itself, at about 1 s on Linux, is the floor for a search with no
index.

### 1.5 Pathological input

`fixtures/patho`, `HEAD~1..HEAD`. Each file is changed between the two commits.

| File | What happens |
|---|---|
| 60-level-deep path, 64 MB binary, rename chain a→b→c→d, CRLF, Latin-1 text, Latin-1 file name (index only) | All fine: settled in 4.6–76 ms |
| `longline.swift`, one 150 KB line | Settled in 291 ms |
| `megaline.swift`, one 1 MB line | Frame **223 ms**, settled 480 ms, then **7.7 GB footprint peak** and 49 CPU-seconds over the next 17 s |
| `million.c`, 1,000,000 lines | Settled **9.7 s**, **7.9 GB peak**, 55 CPU-seconds in 16 s across 3–4 cores |
| `minified.min.js`, 10 MB on one line | **Never finished.** Opened alone: 55 CPU-seconds in 18 s and an 8.1 GB peak. Reached after `million.c`: one core for the whole 380 s until the timeout, settling at 1.7–3.3 GB |

The main thread stayed responsive through the minified file: the largest wait
was 475 ms, at open. The costs come from these places:

* **There is no size limit on analysis.** `FileState.analyze`
  (`Document.swift:187`) and `ContentAnalysis.analysis`
  (`ContentAnalysis.swift:55`) parse and highlight any file. The 4 MB limit in
  `readWorktreeFile` and the "not worth parsing" check apply only to the
  definition index.
* **The work can't be cancelled.** The parse and query run in `Task.detached`
  (`ContentAnalysis.swift:61`). Neither the tree-sitter parser nor the query
  cursor gets a cancellation or progress callback. Moving to another file
  leaves the core busy.
* **The highlights query is quadratic on long lines.** The samples are all in
  `SyntaxLanguage.tokens(in:)` (`Syntax.swift:109`):
  `ts_query_cursor_next_match` and `ResolvingQueryMatchSequence`. They then go
  through predicate resolution through `Substring.index(_:offsetBy:)`, which
  walks from the start of the text for each capture.
* **Each version is parsed several times.** The old and new sides are parsed
  concurrently, which is correct. `Names.names(of:)` (`Names.swift:296`) then
  parses each side again for locals. The 1 MB line had four parsers running at
  once, each building a deep GLR stack (`ts_stack_pop_count`), and that is
  where the 7.7 GB went.
* **The caret redraw is quadratic in the length of the line.** `caretRect`
  (`CodeView.swift:597`) calls `identifier(at:)` (`CodeView.swift:1054`), which
  scans outward one UTF-16 unit at a time through `CharacterSet` until it
  leaves the identifier. On `megaline` that is the whole 1 MB line. It then
  calls `boundingRect` over it, on every draw: 184 of 227 samples in
  `CodeView.draw`.

The 64 MB binary and the very long diff line are handled well. The binary is
detected and not shown. Word diff is capped at 250k cells per pair
(`WordDiff.swift`).

### 1.6 Memory

**Footprint after opening ghostty** (`mem-work`): 194 MB. Of that, 93 MB is
owned graphics memory (backing stores, which are purgeable), 43 MB is
`MALLOC_SMALL` and 17 MB is IOSurface. **The live heap is only 28 MB**
(215,000 nodes). In the overview the footprint is 91 MB, because the graphics
memory is released while those views aren't drawn. The glass look costs about
85 MB more than classic at idle (193 MB against 108 MB). Most of that is
backdrop and blur surfaces.

**Peaks.** Reading: 381 MB (ghostty overview), 488 MB (Linux), 624 MB
(10,000-file overview). Go to Anything on Linux: 909 MB. Pathological files:
**7.7–8.1 GB**.

**Soak** (2 minutes, 30 cycles of navigation, an agent editing every 2 s and
committing every minute; `soak-short`): the footprint ends at 167 MB, peaks at
419 MB, and the live heap is 72 MB (534,000 nodes). `leaks` finds 209 objects
totalling 11 KB, almost all in a system XPC connection
(`LNDaemonApplicationInterface`). **The app leaks nothing of note.**

**Longer soak** (`soak-long`, the same cycle, stopped after 98 of 350 cycles
and 7.2 minutes because the app's beeps were disturbing someone at the
machine):

* **The footprint at the cycle marks rises steadily:** 209 MB at cycle 1,
  268 MB at 21, 308 MB at 41, 362 MB at 71, 409 MB at 91 and 423 MB at 98.
  That is about 30 MB a minute, which would pass 2 GB within the hour if it
  went on. Between marks the footprint swings by 150 MB as graphics memory
  comes and goes. The peak was 524 MB.
* **Timings stay flat.** Next File settles in 17–28 ms throughout. All
  Changes creeps from 29 to 46 ms, Side by Side stays at 47–65 ms, and Older
  Commit at 111–223 ms.
* **The agent alone costs CPU continuously.** Over the 6.5 minutes there were
  4,234 git processes, 100 s of git CPU and 120 s of app CPU, with 384
  main-thread waits over 50 ms. Commit stepping accounts for about 2,500 of the
  processes, and the agent's edit every 2 s for the rest.
* **The growth isn't attributed.** The heap, vmmap and leaks inspection was
  due at the end and didn't run. The likely candidates are `FileState`
  retained for every file and commit visited, and the token cache filling its
  1M-token budget. Neither is bounded by bytes (F10). This is the most
  important memory measurement still to make: a silent version of the soak
  (section 5).

**Caches and whether they're bounded:**

| What | Bound | Notes |
|---|---|---|
| `ContentAnalysis.recent` (tokens) | 1M tokens (`ContentAnalysis.swift:37`) | Counted in tokens, not bytes. Eviction scans the whole cache (`RecentlyUsed.insert`, `min`), so it's O(n) per insert |
| `ContentAnalysis.definitions` | Pruned only when it holds more than 3× the current set | 1.44M definitions on Linux. Kept in memory twice, as `[ContentKey: [Definition]]` and as each session's `[LocatedDefinition]` |
| `FileState` (lines, tokens, names, word ranges, outline) | **None**: kept for the life of the session | Every file visited stays fully analyzed |
| `ObjectReader.readers` | **None**: one `cat-file --batch` process per repository for the app's lifetime (`Objects.swift:25`) | Closing a window doesn't end its process |
| Navigator tree, snapshot file list | Rebuilt rather than cached | Costs time, not memory |

**Per pane:** about 16 MB (section 1.2). **Per window:** see section 1.2.

### 1.7 Idle

| State | CPU | Wake-ups/s | Git |
|---|---|---|---|
| Focused, after settling (`idle-focused-sample`) | 24 ms in 15.6 s | 2.2 | 0 |
| Focused, 5 s after opening (`idle-focused`) | 95 ms in 15 s | 14 | 0 |
| In the background, after opening (`idle1`) | 190 ms in 31.6 s | 7.7 | 0 |
| Hidden | 5 ms in 30 s | 0.5 | 0 |
| Unrelated writes elsewhere on disk | ≈0 | 1 | 0 |
| Ignored writes (`zig-out/`, 20 a second) | **one full refresh** once they stop | — | 11–12 |
| One tracked append a second | 2.7 s app and 8.6 s git CPU in 20 s | — | **240** |

Idle is at the floor: no timers, and the read-only text view doesn't blink a
caret. One fault to note: the theme watcher (`Theme.swift:317`) watches the
nearest existing ancestor of `~/.config/sextant/themes`. On this machine that
is `~/.config`, watched recursively. Without `~/.config` it would be the home
directory, and the app would wake for every write under it. I found this in the
code and didn't measure it, so I wouldn't write into `~/.config`.

### 1.8 Launch

Warm launch, five runs on `work` (`launch-1` to `launch-5`):

| Step | Time from process start |
|---|---|
| Automation script starts (AppKit up) | 106–119 ms |
| Window shown | 266–287 ms (`openRepo` + 160–170 ms) |
| Content shown | 290–307 ms |
| Settled | 501–613 ms |

Launch costs 816–858 ms of app CPU and 641–675 ms of git CPU, with 17 git
processes. Five of those are `status` runs, one per worktree, started at
246 ms. The footprint peaks at 204–222 MB and settles at 103–106 MB. The git
work before content is fast (the diff finishes at about 75 ms). The window is
the long pole. The bundle names git in `SextantGitPath`, so the login-shell
`PATH` lookup (30 ms with fish) never blocks the first window.

I couldn't measure a cold launch: section 5.

### 1.9 Rendering

The window was in the foreground, with WindowServer CPU taken from
`/usr/bin/top` (`render-*`):

| | Glass | Classic |
|---|---|---|
| Idle footprint | 193 MB | 108 MB |
| Scrolling a file, 300 steps: app CPU | 266–290 ms | 201 ms |
| Scrolling: WindowServer CPU | **7.5%** | 2.9–4.3% |
| Scrolling: frame median | 0.3 ms | 0.2 ms |
| Live resize, 26 steps: app CPU | 3.15–3.18 s | 2.7 s |
| Live resize: main-thread waits over 8.3 ms | **150–165** | 7–10 |
| Live resize: WindowServer CPU | **35.7%** | 16–25% |
| Overview scroll: app CPU, frame median | 1.4 s, 0.9 ms | 1.5 s, 0.9 ms |

Glass roughly doubles WindowServer's work while scrolling and resizing. Some of
that is the blur, which is the price of the look. The live resize sample is
confounded by Hammerspoon, which resizes windows over Accessibility (2,700 of
8,579 main-thread samples). Sextant's own share has avoidable parts:

* `GutterScrollView.tile` (`CodeView.swift:1399`): 215 samples. On every tile
  it searches the ruler's view tree recursively for materials, through
  `containsMaterial`.
* `drawPill` (`CodeView.swift:785`): about 190 samples. It creates the chevron
  symbol image on every draw.
* `Appearance.defaultsChanged` (`Theme.swift:301`): 26 samples. Every frame
  autosave posts `UserDefaults.didChangeNotification`, and the handler builds a
  signature string from six defaults each time.
* `CodeView.draw`: 237 samples.

### 1.10 Processes and threads

| Operation | Git processes |
|---|---|
| Launch (`work`, five worktrees) | 17 |
| Any refresh | 11–12, plus 1 per extra worktree, plus 0–3 diff retries |
| Older Commit / All Commits (four steps) | 26 |
| Find References / Peek | 2 (`grep`, `ls-tree`) |
| Go to Anything, first open | 1 (`ls-tree`), with blobs read through the long-lived `cat-file --batch` |

`Git.run` (`Git.swift:28`, `:53`, `:61`, `:65`) holds up to three
blocking-capable GCD threads for each process. One blocks in
`readDataToEndOfFile` on stdout and another on stderr. Then `waitUntilExit`
spins a run loop. Five concurrent `status` calls park 10–15 threads on pipes.
The thread count peaked at 20–26 under load and fell to 7–9 at idle. This
costs no CPU, but it is waste, and it brings GCD's 64-thread limit closer
during bursts.

## 2. Findings, ranked

The ranking is by how badly each finding undercuts the claim. It weighs how
often the case comes up with agents and large projects, and how bad the result
is. Every fix is sized by what it touches. "Small" is one function. "Medium" is
a few files and a new data structure. "Large" replaces a subsystem.

### F1. Change detection is a boolean, so every event redoes the whole repository

* **Evidence.** `RepoWindowController.swift:844–865`, `Repository.swift:74`,
  `:118`, `Refs.swift:76`, `Review.swift:160`, `Git.swift:169`,
  `Explore.swift:63`, `RepoWindowController.swift:451`, `Navigator.swift:434`.
  * Every refresh runs 12 processes, plus one per extra worktree.
  * One edit on the 300,000-file checkout costs 9.5 CPU-seconds, with
    155 ms of main-thread stalls.
  * A Linux refresh costs 7.8 s of git CPU.
  * Ignored build output costs 23 processes and 1.5 s of git CPU.
  * Five worktrees cost 412 processes in 30 s, about half a core.
  * Sustained writes left the screen stale for 22 s.
  * Convergence takes 0.5–1.1 s, against a floor of about 0.2 s.
* **Waste.** Nearly all of it:
  * refs and ahead-behind re-read when no ref moved;
  * `status` for worktrees that didn't change;
  * a commit log of up to 1,000 commits when HEAD didn't move;
  * a whole-tree diff for a one-file change;
  * the snapshot file list re-listed and re-stat'd;
  * the navigator rebuilt;
  * the diff retried synchronously while files are still being written.
* **Necessary but slow.** A one-path diff is needed. Today it is computed as a
  whole-tree diff.
* **Fix** (section 3, layer 1).
  * Classify the FSEvents paths:
    * refs and HEAD;
    * the index of worktree W;
    * a file in worktree W;
    * ignored.
  * Filter ignored paths through a long-lived `git check-ignore --stdin` or an
    in-process matcher.
  * Replace the trailing debounce with a throttle that fires on the leading
    edge and then at most every 100–200 ms. This bounds staleness during
    sustained writes.
  * Re-read only what each class affects:
    * refs only when refs change, with ahead-behind only for the refs that
      moved;
    * `status` only for worktree W;
    * the commit log only when the base or HEAD moves;
    * `git diff -p -M -- <paths>` for the changed paths only.
  * Merge the results into a per-path model.
  * Replace the mtime retry with FSEvents event IDs. If events arrived for a
    path while its diff ran, schedule that path again instead of rereading
    everything.
  * Keep the snapshot file list in the model, updated from adds and deletes.
  * For the 300,000-file case, give git the changed paths through its
    `core.fsmonitor` hook protocol: Sextant already has them from FSEvents. Run
    git with `-c core.fsmonitor=<Sextant's hook> -c core.untrackedCache=true`,
    and `status` and the worktree diff stop stat'ing every file. That removes
    the 10 s of system time. With git's own fsmonitor daemon standing in for
    Sextant's hook, `status` fell from 1,025 to 214 ms and the worktree diff
    from 814 to 28 ms. With a pathspec, one path takes 25–32 ms (section 1.3).
* **Cost.** Medium to large: a new repository-state model replacing
  `Repository.refresh` and `RepoWindowController.refresh/load/apply`, about
  1,000–1,500 lines. Renames that span classes and rebase storms have to be
  correct, so this needs fault-injection tests in the agents harness.
* **Tradeoff.** More states to get right. The per-path model has to fall back
  to a full reload on anything it can't classify, such as packed-refs rewrites,
  `git gc`, or a lost FSEvents history (`kFSEventStreamEventFlagMustScanSubDirs`).
  A full reload then becomes the exception rather than the rule.

### F2. Nothing bounds or cancels the analysis of a file

* **Evidence.**
  * The analysis has no size limit (`Document.swift:187`,
    `ContentAnalysis.swift:55`) and runs in a detached task that can't be
    cancelled (`ContentAnalysis.swift:61`).
  * Each version is parsed twice (`Names.swift:296`).
  * The highlights query is quadratic (`Syntax.swift:109`).
  * The caret scans the whole line on each draw (`CodeView.swift:597`, `:1054`).
* **Measurements.**
  * 1 MB line: 223 ms frame, then 7.7 GB and 49 CPU-seconds.
  * 1M lines: 9.7 s to settle, 7.9 GB.
  * 10 MB minified: never finishes, one core for more than 6 minutes, and up
    to 8.1 GB.
* **Waste.** All the work after the user leaves the file. Parsing every
  version twice. Highlighting 10 MB that nobody reads.
* **Fix.**
  * Degrade above thresholds: no syntax or names analysis for a side over
    about 2 MB or with a line over about 20,000 UTF-16 units. VS Code uses the
    same kind of cutoff, and so do Xcode and Zed. Show such a file as plain
    text with a note.
  * Parse once per version and run highlights, locals and tags against the
    same tree.
  * Give the parser a progress callback that checks for cancellation (newer
    tree-sitter has `ts_parser_parse_with_options`, and older versions have
    `ts_parser_set_timeout_micros`), and give the query cursor a range limit.
  * Cancel when no reader holds the file any more.
  * Resolve predicates over UTF-8 byte offsets instead of `Substring` index
    walking.
  * Cap the caret's identifier scan, for example at 256 units, and get the
    token from the tokens already computed.
* **Cost.** Small: 100–200 lines across `ContentAnalysis`, `Syntax`, `Names` and
  `CodeView`.
* **Tradeoff.** Huge files lose colour. That is the right trade: nobody
  reviews a minified bundle by colour, and they would much rather not lose
  their machine.

### F3. Go to Anything costs about 1.2 µs per candidate per keystroke and holds 760 MB at Linux scale

* **Evidence.** `Jump.swift:13`, `:242`, `JumpActions.swift:66`,
  `ContentAnalysis.swift:161`. On Linux, each keystroke costs 1.6–2.0 CPU-seconds;
  the index adds 760 MB and rewrites a 64 MB JSON file.
* **Waste.**
  * Lowercasing everything again on every keystroke.
  * Re-ranking the whole set when the query only got longer.
  * Fully sorting every match to take the top 60.
  * Rankings that can't be cancelled pile up.
  * The JSON file is rewritten whole after each analysis that found symbols.
* **Fix.**
  * Build a candidate table once per index: names and paths as lowercased
    UTF-8 in one byte arena, a 64-bit letter mask per candidate for rejection
    in one instruction, and the kind and file as small integers.
  * Per keystroke, scan with byte-level matching, select with a top-k heap,
    and check for cancellation every 4,096 candidates. When the query extends
    the previous one, scan only the survivors.
  * Use structured tasks so that cancelling works.
  * Persist the index as a binary file, or as one segment per blob set that
    new segments are appended to, instead of re-encoding the whole JSON file.
* **Measured floor.** `bench/fuzzy.c` implements this with fuzzyScore's
  scoring, on one core, over the same 1,532,591 Linux candidates:
  * The table builds in 80–90 ms.
  * Ranking from scratch takes **1.7–35 ms per keystroke**. The slowest are one-
    and two-letter queries that match 340,000–1,000,000 candidates.
  * Narrowing from the previous keystroke takes **under 1 ms from the fifth
    character on**. For `kmalloc_node` it falls from 9.3 ms at `km` to 0.00 ms.
  * Today the app takes 1,600–2,000 ms per keystroke, so the floor is 50–1000×
    faster. Spreading the first keystrokes across cores would put every
    keystroke inside one frame.
  * The table's text is 55 MB with paths repeated. Interned paths and 24-byte
    entries bring it to about 60 MB in total, against the 760 MB held today.
* **Cost.** Medium: `Jump.swift`, `DefinitionIndex`, the persistence in
  `ContentAnalysis`, and the panel. About 400 lines.
* **Tradeoff.** None visible to the user. Results stay identical as long as the
  scoring function is kept.

### F4. Overview edits re-render the whole overview, and the TextKit replace is quadratic

* **Evidence.** `RepoWindowController.swift:874`, `:881`, `Reader.swift:116`,
  `:255`, `CodeView.swift:252`. In the 10,000-file overview, marking reviewed,
  Bigger, Smaller and adding a note each take 2.9–3.7 s, with 2.16 of 2.17 s in
  `NSMutableRLEArray` `memmove`. At Linux scale they take 153–327 ms, and on
  synth 111–697 ms.
* **Waste.** Rendering and laying out every file to change one file's header
  or collapse state. Rendering every pane again for one note.
* **Fix, in two steps.**
  1. Small: replace the text storage's contents with a delete followed by an
     append inside `beginEditing`/`endEditing`. Alternatively, build the
     rendered string directly as an `NSTextStorage` and swap it in with
     `layoutManager.replaceTextStorage`. Either way the quadratic run insert
     goes away. Expect about the cost of the first All Changes, 313 ms, in
     place of 2.9 s.
  2. Right: make the overview a sequence of per-file blocks, so that a change
     to one file replaces that block's character range
     (`replaceCharacters(in:with:)` over its rows) and shifts `rowStarts` by
     the difference. Reviewed state, notes and folds touch one block. A font
     change still re-lays out everything, but only the visible part needs to
     be done before the next frame.
* **Cost.** Step 1 is small, about 20 lines. Step 2 is medium, in `Reader` and
  `CodeView`'s row bookkeeping.
* **Tradeoff.** Step 2 adds offset bookkeeping, which is the price of
  incremental updates.

### F5. The navigator rebuilds a tree of every path on the main thread

* **Evidence.** `Navigator.swift:397`, `:434–448`, `:644`, `FileTree.swift`.
  * Mark reviewed costs 61 ms on ghostty, 188 ms on Linux and 593 ms on the
    300,000-file repository.
  * Each apply on synth spends about 100 ms rebuilding.
  * Each filter keystroke repeats the rebuild with `rankFuzzy` on the main
    thread.
* **Waste.** Rebuilding to change one row's reviewed checkmark.
* **Fix.**
  * Keep the tree as a persistent model updated by path insert and remove.
  * Reload only the changed item with `reloadItem`.
  * Build children lazily on expand.
  * Filter off the main thread, with the same candidate table and cancellation
    as F3.
* **Cost.** Small to medium: about 200 lines in `Navigator` and `FileTree`.
* **Tradeoff.** None.

### F6. Opening a review waits for ahead-behind counts for every branch, and every refresh computes them again

* **Evidence.** `Repository.swift:235`, `Refs.swift:76`. On the Linux shallow
  clone, content takes 8.8 s to appear (6.4–6.7 s of it in `for-each-ref`), and
  each refresh costs the same 6.5 s again.
* **Waste.** Counts that only the review picker shows, computed before the
  first frame and on every file change.
* **Fix.**
  * Resolve and show the review first, and read refs concurrently.
  * Compute ahead-behind lazily, only for the branches in the visible part of
    the picker.
  * Cache each count by (branch oid, base oid) so that it is computed at most
    once per commit pair.
  * Never compute counts in a refresh unless a ref moved.
* **Cost.** Small: about 100 lines.
* **Tradeoff.** The picker shows a placeholder for a moment the first time.

### F7. The snapshot file list is rebuilt, re-stat'd and sorted on the main thread for every apply

* **Evidence.** `Explore.swift:63` and `RepoWindowController.swift:442–460`. On
  synth, the existence check costs 1.2 s per edit and the sort costs 24 ms on
  the main thread. On Linux, Older Commit takes about 1 s.
* **Waste.** All of it when only the worktree changed. The 300,000 stat calls
  confirm what `status` already reported.
* **Fix.**
  * Derive the list from the index plus the review's adds and deletes, and
    keep it in the layer-1 model.
  * Sort with a byte-wise or precomputed key off the main thread.
  * Cache by tree oid for commit snapshots.
* **Cost.** Small, as part of F1.
* **Tradeoff.** None.

### F8. Lookups grep the whole tree again every time

* **Evidence.** `WindowActions.swift:239`, `:258–322`, `:533`,
  `DefinitionIndex.swift:35`. On Linux, Find References takes 1.4–2.3 s and
  Peek 1.2 s, with 5.5–7 s of git CPU each, and a repeated lookup costs the
  same as the first.
* **Waste.**
  * Repeated identical greps.
  * Peek ignores the definition index that Go to Anything built.
* **Necessary but slow.** The first `git grep`. At about 1 s on Linux, it is
  the floor for a search with no index.
* **Fix.**
  * Cache `(snapshot, word) → matches` until the snapshot changes.
  * For Peek and Jump to Definition, look the name up in the definition index
    first when it exists. That answers in microseconds. Fall back to grep.
* **Cost.** Small.
* **Tradeoff.** Cache invalidation follows the snapshot's identity, which the
  layer-1 model provides.

### F9. The glass look doubles WindowServer's work while scrolling and resizing, and the app adds avoidable work per frame

* **Evidence.** Section 1.9. Glass uses 85 MB more than classic at idle.
  WindowServer CPU is 7.5% against 2.9–4.3% while scrolling, and 35.7%
  against 16–25% while resizing. There are 150–165 main-thread waits over
  8.3 ms during resize, against 7–10 for classic.
* **Waste.**
  * The recursive material search in `GutterScrollView.tile`
    (`CodeView.swift:1399`).
  * The symbol image created in every `drawPill` (`CodeView.swift:785`).
  * The defaults signature rebuilt on every `didChangeNotification`
    (`Theme.swift:301`).
* **Necessary.** The blur's compositing cost.
* **Fix.**
  * Keep a reference to the material view instead of searching for it.
  * Cache the pill icon per style.
  * Observe the specific keys with KVO instead of every defaults change.
  * Measure resize again without Hammerspoon before attributing more.
* **Cost.** Small.
* **Tradeoff.** None. The look stays the same.

### F10. Per-file state lives for the whole session, and some caches have no bound

* **Evidence.**
  * `FileState` keeps lines, tokens, names, word ranges and the outline for
    every file visited.
  * `ObjectReader.readers` is never emptied (`Objects.swift:25`).
  * `RecentlyUsed` is bounded in tokens, not bytes, and evicts in O(n).
  * The definitions are held twice (F3).
* **Measurements.**
  * About 16 MB per pane.
  * The live heap grows from 28 MB at open to 72 MB after 2 minutes of the
    soak.
  * The footprint grows from 209 to 423 MB over 7 minutes of navigation and
    agent edits, at about 30 MB a minute and still rising (`soak-long`). Which
    of these causes contributes most to that growth isn't measured yet.
* **Fix.**
  * Make `FileState` analysis a cache in front of `ContentAnalysis`: keep the
    rows on screen and in the neighbouring files, and drop the rest under a
    byte budget.
  * Close a repository's `cat-file` when its last window closes.
  * Measure the cache by bytes, and evict with a linked LRU in O(1).
* **Cost.** Small to medium.
* **Tradeoff.** Revisiting a dropped file costs a cache lookup. Its blob
  analysis is still cached by oid.

### F11. Each git process blocks up to three threads

* **Evidence.** `Git.swift:28–66`. The thread count peaks at 20–26, with
  10–15 threads parked during concurrent `status` runs.
* **Fix.**
  * Spawn with `posix_spawn`.
  * Read stdout and stderr with `DispatchSourceRead`, or `DispatchIO`.
  * Reap with a `DispatchSource.makeProcessSource(.exit)`.
  * Run no thread per process.
* **Cost.** Small: about 120 lines, in one place.
* **Tradeoff.** None.

### F12. Smaller items

* `wordRanges` (`Document.swift:398`) computes word-level pairs for the whole
  file on the main thread the first time it is used.
* `layoutRows` (`Document.swift:462`) is O(files × notes × lines), through
  `anchor(of:)` (`Document.swift:425`). It doesn't matter yet, but it will
  matter for a review with hundreds of notes.
* In the overview, `analyzeShownFiles` (`Reader.swift:197`) walks every file
  and runs an O(n) `nextToAnalyze` per step. That is quadratic in the number
  of files, and it isn't ordered by what's on screen.
* Gutter `numberColumnWidth` (`CodeView.swift:1125`) reduces over every file,
  once for each layout.
* The theme watcher can watch all of `~` recursively (section 1.7).
* The 10,000-file overview scrolls at p90 21–34 ms a step (section 1.4).

## 3. The data architecture I'd want

The design principle: **every layer keys its work by content identity and
propagates deltas, so that the cost is proportional to what changed or what's
on screen.** Git already works this way: objects are immutable, trees are
Merkle trees, the index has stat data, and fsmonitor exists. The app should
follow git's shape rather than flatten it into "reload".

```
FSEvents (paths + event IDs) ──► L1 repository model ──► L2 review model ──► L3 rows ──► L4 pixels
git objects (cat-file --batch) ─► content store (by blob oid) ──────────────┘
```

**L0, input.** One FSEvents stream per repository, shared by every window and
pane, covering the common directory and every worktree root. Each path is
classified as refs/HEAD, the index of worktree W, a file in worktree W, or
ignored (by a long-lived `check-ignore --stdin` or an in-process matcher).
Event IDs are kept, so that a diff can say "I saw changes up to event N". A
throttle fires on the leading edge, then at most every 100–200 ms, so updates
keep coming while an agent writes.

**L1, repository model** (an actor per repository):

* refs, read only when refs change, with ahead-behind lazily per ref pair and
  cached by oids;
* worktrees, and per worktree a map from path to (index oid, worktree oid,
  mtime);
* the snapshot file list per tree oid, cached, and per worktree maintained
  from the index and status deltas.

`status` and `diff` take `-- <paths>` from L0. For very large checkouts,
Sextant gives git its changed paths through the `core.fsmonitor` hook
protocol, so git never stats the whole tree. Its output is a delta: paths
added, removed or changed, with oids.

**Content store** (exists: `ContentAnalysis`). Everything here is keyed by
(blob oid, grammar version) and immutable:

* the lines, with UTF-16 offsets;
* one syntax tree, which gives tokens, locals and tags in one pass;
* the definitions.

It is shared across panes, sessions and windows, bounded by bytes with an O(1)
LRU, and cancelled when nothing waits for it. Size thresholds degrade huge
blobs to plain text. Worktree edits to a cached blob reuse the old tree through
tree-sitter's incremental `ts_tree_edit` and reparse. Definitions persist in a
compact binary segment store, appended to as new blobs are analyzed.

**L2, review model.** A review is (base, target). Its file list is a map from
path to (old oid, new oid, mode, rename source). The diff for each path is
computed from the two oids, or from the worktree path, and cached by that key.
An L1 delta becomes "these paths changed", and only those diffs are computed
again. Two FileDiffs are equal when their oid keys are equal, without comparing
lines. The commit list is cached by (base oid, head oid).

**L3, rows.** The rows for each file are a pure function of (diff key, mode,
folds, notes on that file, review state), cached per file. The overview is the
concatenation, with a prefix-sum of row heights (a Fenwick tree, for O(log n)
updates), so a change to one file updates its block and shifts the offsets of
the blocks after it.

**L4, pixels.** Layout and draw only the viewport, so that cost is
proportional to the rows on screen.

* **The cheapest route** keeps TextKit 1 (non-contiguous layout and temporary
  colour attributes already work this way). Edits become per-block
  `replaceCharacters`, and the prefix-sum replaces `rect(ofRow:)`'s
  layout-from-zero.
* **The full route** is a custom view that draws cached `CTLine`s for the
  visible rows. Its cost is O(visible rows) regardless of overview size, which
  is what makes a 450,000-row overview feel like a 50-row file. TextKit 2's
  viewport layout is the middle option, at the cost of migrating the colour and
  selection code.

The navigator and Go to Anything read L1 and L2 deltas. The navigator keeps a
persistent tree with lazy children. Go to Anything keeps a candidate table
(F3), extended as the content store analyzes new blobs.

**What already fits:**

* The content-addressed analysis: `ContentKey` (blob oid plus grammar),
  `ContentAnalysis` shared across readers, and definitions persisted per blob.
* The long-lived `cat-file --batch` `ObjectReader`.
* FSEvents with file-level events. The paths are already delivered; they're
  just reduced to a boolean.
* The equality early exit in `apply`, which has the right idea in the wrong
  place.
* Colouring only visible rows with temporary attributes, non-contiguous layout,
  and `afterFrame` deferral of work that isn't visible.
* Occurrence boxes that only redraw the rows that changed
  (`CodeView.showOccurrences`). That one is exactly the L3/L4 delta discipline.
* One `Repository` per repository, shared by the window's panes.
* The automation harness with `measure`, which can run the budgets below in CI.

## 4. Budgets

The budgets are justified by perception and hardware:

* **One frame at 120 Hz is 8.3 ms.** The main thread must finish input handling
  and drawing in that time, leaving room for the commit and the compositor.
* **100 ms** is the limit below which a response feels instantaneous.
* **One second** is the limit below which a user doesn't lose their train of
  thought.
* **Idle** should cost nothing: a laptop on battery with three Sextant windows
  open beside agents.

| Scenario | Budget | Justification | Now | Meets? |
|---|---|---|---|---|
| Scroll (file or overview), main thread per frame | ≤ 4 ms p99, 0 frames over 8.3 ms | Half a frame, so the compositor never misses | File 0.3 ms. Overview on ghostty p90 6.8, max 9.8. Linux p90 9.3–16. 10k files p90 21–34 | File yes. Overview no at scale |
| Next and previous file | ≤ 8.3 ms frame, ≤ 50 ms settled | One frame to respond, colour within the 100 ms limit | 6.8 ms (p90 20–27), 25–29 ms settled | Mostly. p90 misses |
| Mode switches, mark reviewed, zoom, notes, any review size | ≤ 16.7 ms frame, ≤ 100 ms settled | Two frames is acceptable for a structural change. 100 ms feels instantaneous | 41–97 ms on ghostty. 176–697 ms on Linux and synth. 2.9–3.9 s at 10k files | No |
| Commit stepping | ≤ 100 ms settled | It is a keystroke | 145–245 ms on ghostty, about 1 s on Linux | No |
| Agent edit to screen right | ≤ 250 ms after a write. While writes continue, updates at least every 500 ms | FSEvents 100 ms, a delta diff, one apply | 0.5–1.1 s. No updates during sustained writes | No |
| Agent edit cost | ≤ 3 git processes and ≤ 20 ms app CPU per batch on ghostty size. ≤ 50 ms of total CPU on the 300k repository | Work proportional to what changed | 22–33 processes and 0.4–1.1 s app CPU. 9.5 s on the 300k repository | No |
| Ignored or unrelated writes | 0 git processes, ≤ 1 ms CPU per batch | Nothing reviewable changed | Unrelated: yes. Ignored: a full refresh | Half |
| Refresh with nothing changed | 0 git processes | — | 11–12 processes, 0.55–7.8 s git CPU | No |
| Several worktrees | Cost proportional to the worktree that changed | — | Every refresh runs `status` in all N worktrees | No |
| Launch, warm | ≤ 250 ms to content, ≤ 400 ms settled | One blink. AppKit up at about 110 ms leaves 140 ms | 290–307 ms to content, 501–613 ms settled | Close, not yet |
| Launch, cold | ≤ 600 ms to content | Disk and dyld | Not measured | ? |
| Open on Linux or 300k files | ≤ 500 ms to content | Git's own floor here is 230–350 ms for the diff | 8.8 s Linux, 574 ms synth | No |
| Go to Anything, per keystroke | ≤ 8.3 ms at 100k candidates, ≤ 30 ms at 1.5M | Results at typing speed | 1.6–2.0 s at 1.5M | No |
| Go to Anything, index memory | ≤ 100 MB at 1.5M definitions | About 40 bytes per definition | +760 MB | No |
| Find References / Peek | ≤ 300 ms on ghostty, ≤ 1.2 s on Linux, ≤ 20 ms repeated or indexed | `git grep` floor | 1.2–2.3 s on Linux, no cache | No |
| Pathological file | ≤ 500 ms to show, ≤ +200 MB, no work after leaving it | — | 9.7 s, never, and 7.7–8.1 GB | No |
| Memory, ghostty review | ≤ 150 MB steady, ≤ 250 MB peak, ≤ 10 MB per extra pane | Native app, below a browser tab | 95–105 MB steady (classic 108, glass 193). Peak 220–381 MB. About 15 MB per pane | Steady yes. Peak and per pane, no |
| Memory, hour of use | Growth ≤ 20% over the hour, no leaks | Caches bounded | No leaks. 209 → 423 MB in 7 minutes, still rising | Leaks yes, growth no |
| Idle, any state | ≤ 1 wake-up/s, ≤ 1 ms CPU/s, 0 git | Battery | Hidden 0.5 wake-ups/s and 0.2 ms/s. Focused 2.2 wake-ups/s and 1.5 ms/s | Hidden yes. Focused just over |
| Glass against classic | ≤ 1.3× WindowServer CPU, ≤ +30 MB, no extra frames over 8.3 ms | The look shouldn't cost frames | 1.7–2.6× scroll, 1.4–2.2× resize, +85 MB, 150 against 8 waits | No |

## 5. What I couldn't measure or am not sure of

* **Cold launch.** Purging the file cache needs `sudo purge`, and I didn't have
  it. Every launch measured was warm.
* **True dropped frames.** Without `xctrace` I can't see display-link presents.
  "Frame" is the main thread's handling time plus `displayIfNeeded`. The probe's
  main-thread latency (pinged every 4 ms) stands in for jank. A frame can still
  be dropped by the render server when the main thread is idle, especially with
  glass, so the WindowServer CPU numbers are the closest evidence.
* **GPU time** of the glass materials isn't measured. WindowServer CPU is
  shared with other apps: Zoom and another agent's Revue.app were running.
* **Live resize** is confounded by Hammerspoon, which resizes windows over
  Accessibility on this machine (about 30% of main-thread samples).
* **The Linux numbers come from a shallow clone.** Ahead-behind is
  pathological there because a commit-graph can't be written. In a full clone
  with a commit-graph, `for-each-ref` with ahead-behind should be far cheaper.
  F6 still applies to repositories with hundreds of branches, but I haven't
  measured how much a deep clone costs.
* **The probe perturbs what it measures.** It adds a thread and about 250
  wake-ups a second, so wake-up counts come from runs without it.
  Automation holds a `beginActivity(.userInitiated, .latencyCritical)`
  assertion, which disables App Nap and timer coalescing. Real idle should be
  at least as quiet as measured.
* **Typing latency in Go to Anything** is inferred from CPU per keystroke on one
  core, not from the time until the results were drawn.
* **The cause of the 7.7–8.1 GB peaks is inferred.** Samples show four
  concurrent tree-sitter parses with deep GLR stacks, and the peak tracks the
  parse. I didn't take a heap snapshot at the peak.
* **One run was interrupted.** About 100 s into the first 300,000-file Go to
  Anything run, the test app was brought to the front, typed into and quit
  cleanly (exit 0; the system log shows `SETFRONT`). The cause was outside the
  run, either a person at the machine or another agent. I re-ran it shorter. The
  five-pane run's final state dump came back empty (likely
  `JSONSerialization` refusing a NaN), so the pane count there is inferred from
  the log and the memory growth.
* **Notes** were measured through code reading and the identical reload path
  (`notesChanged` reloads every pane, as Bigger does), not by typing a note.
  The note editor is a popover, which the background automation can't type
  into.
* **Runs I didn't do**, to avoid disturbing the machine any further:
  * The soak to an hour, with the heap inspection. The cycle beeps, because
    Older and Newer Commit at the ends of the range call `NSSound.beep()`, so
    the script needs commands that stay inside the range.
  * A second open of Go to Anything with the saved index. The jump panel takes
    the keyboard, and one earlier run of it was interrupted.
  * Several windows of different repositories.
  * A sample of the 10,000-file overview scroll. `scripts/windows.txt`,
    `scripts/oscroll.txt` and `scripts/gta-linux-warm.txt` are written and
    ready to run.
* **Microbenchmarks** of the app's own functions (`fuzzyScore`, `fileTree`,
  `parseRawPatchZ`) weren't built. The only microbenchmark is
  `bench/fuzzy.c`, which shows the floor for F3 rather than timing the
  current code. The in-app samples attribute the time precisely enough to rank
  the findings, and the in-app scripts are what later commits should be
  measured against.

## 6. Scripts

Everything is under `scratch/` and reproducible from a clean tree.

* `tools/build.sh` makes the release bundle with the audit's bundle ID, then
  builds `gitwrap`, `psample` and `libprobe.dylib`.
* `tools/make-fixtures.sh [synth|patho|many|ghostty|work|linux|all]` builds the
  fixture repositories. Linux is a 400-commit shallow clone of about 7 GB; check
  disk space first.
* `tools/run.sh <name> <script> [--probe] [--malloc] [--driver cmd]
  [--foreground] [--timeout s]` takes the GUI lock, launches the app on an
  automation script, and records the following into `results/<name>/`:
  * `run.log`;
  * `samples.txt` (CPU, wake-ups, footprint, threads, child CPU and main-thread
    waits every 100 ms);
  * `git.log` (one line per git process);
  * `probe.stalls`;
  * `meta.txt` (commit and load averages).
* `tools/summarize.sh <dir> [from] [to]` gives the cost between two log lines:
  wall time, CPU, git CPU, wake-ups, footprint, threads, git processes and
  main-thread waits.
* `tools/gittime.sh <repo> <base> <head>` times each git command the app runs,
  best of three.
* `tools/probe.c` (main-thread latency and allocation counter, loaded with
  `DYLD_INSERT_LIBRARIES`), `tools/psample.c` and `tools/gitwrap.c` are the
  measurement tools.
* `scripts/read.sh <name> <repo> [spec]` runs the reading suite (section 1.4).
  The results are in `read-work`, `read-linux`, `read-synth` and `read-many`.
* `scripts/agents.sh` and `scripts/analyze-agents.sh` run the agents scenario
  and check convergence (section 1.1). `scripts/phase-costs.sh` gives the cost
  per phase.
* `scripts/worktrees.txt` with `scripts/worktrees-driver.sh` runs five worktrees
  with five staging agents (section 1.2).
* `scripts/refresh.sh` (no-op refreshes) and `scripts/edits.sh` (an edit every
  4 s) measure the refresh cost (sections 1.1 and 1.3).
* `scripts/gta-linux.txt` and `scripts/gta-synth.txt` cover Go to Anything, and
  `scripts/lookups.sh <name> <repo> <spec>` covers references, Peek and Find in
  Files (section 1.4).
* `scripts/patho.txt` steps through every pathological file.
  `scripts/patho-one.sh <name> <query> [delay] [duration]` opens one file and
  samples it (section 1.5).
* `scripts/memory.sh`, `scripts/soak.txt` and `scripts/soak-long.txt`, with
  `scripts/soak-driver.sh`, record footprint, vmmap, heap and leaks
  (section 1.6).
* `scripts/idle.txt` with `scripts/idle-driver.sh`, and
  `scripts/idle-focused.txt`, cover idle (section 1.7).
* `scripts/launch.sh [runs]` times launches (section 1.8).
* `scripts/render.sh <name> <glass|classic>` covers rendering (section 1.9).
* `scripts/many-sample.txt` samples the 10,000-file overview re-render.
* `bench/fuzzy.c` is the ranking floor for F3. Build it with `nix develop -c
  clang -O2 -o scratch/build/fuzzy scratch/bench/fuzzy.c`. Write the
  candidates with `bench/candidates.sh fixtures/linux >
  bench/linux-candidates.tsv` after the app has indexed Linux (`gta-linux`),
  then run `build/fuzzy bench/linux-candidates.tsv kmalloc_node`.

To compare a later commit, rebuild with `tools/build.sh`, rerun the same script
under a new name, and diff the `summarize.sh` lines and the `MEASURE` lines.
