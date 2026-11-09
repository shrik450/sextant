# Argon Scoped Audit: Git Process & Parsing Layer (`argon-git`)

Scope: `Sources/SextantCore/Git.swift`, `Objects.swift`, `Parse.swift`, `Explore.swift`, `Refs.swift`, `Review.swift`, `Model.swift`, `WordDiff.swift`, `SearchPath.swift` (following calls into `Jump.swift`, `WholeFile.swift`, `ContentAnalysis.swift`, `DefinitionIndex.swift`, `Repository.swift`, `Document.swift`, `RepoWindowController.swift`, `WindowActions.swift`, `SubjectPicker.swift`, `CodeView.swift`).

All benchmarks and adversarial reproduction tests were compiled against the real `Sources/SextantCore` files in release mode and live in `/Users/shrik450/Developer/review-ui/scratch/review/argon-sections/git/`.
To rerun all microbenchmarks and adversarial tests:

```bash
cd /Users/shrik450/Developer/review-ui/scratch/review/argon-sections/git && nix develop /Users/shrik450/Developer/review-ui -c swift build -c release && ./.build/release/GitAuditBench
```

---

## 1. Architecture Audit

### Ownership and Data Flow
- **`Model.swift`**: Value types representing git domain entities (`RawChange`, `Commit`, `CommitDetail`, `Stash`, `LineKind`, `DiffLine`, `Hunk`, `FileDiff`, `Target`, `Snapshot`, `GrepMatch`, `Blame`). Flow out of `SextantCore` into `SextantApp` (`Repository`, `FileState`, `RepoWindowController`, `Navigator`, `Inspector`).
- **`Git.swift`**: Stateless `Git(root: URL, executable: String)` process wrapper (`Git.run`) plus ref resolution (`locate`, `head`, `currentBranch`, `defaultBranch`, `mergeBase`, `resolve`, `branches`), history (`log`, `stashes`, `commitDetail`), and diff loading (`diffArgs`, `diff`, `loadDiff`, `untrackedFiles`, `hashObjects`, `worktreeMode`, `readWorktreeFile`, `oldLines`).
- **`Objects.swift`**: `ObjectReader`, a per-`(executable, root)` singleton managing a persistent `git cat-file --batch` child process over pipes on a serial `DispatchQueue` (`sextant.cat-file`). Extended onto `Git` via `Git.blob(_:)`.
- **`Parse.swift`**: Pure parsers transforming raw `Data` / `Substring` outputs from git into `Model` types: `unquoteGitPath`, `parseRawMeta`, `parseRawPatchZ`, `splitPatches`, `parseHunkHeader`, `parseFilePatch`, `parseLog`, `parseDecorations`, `parseRawLine`, `untrackedFileDiff`, `splitLines`.
- **`Explore.swift`**: Snapshot-scoped exploration operations on `Git` (`files(in:)`, `contents(of:in:)`, `grep(_:in:...)`, `blame(_:in:)`, `history(of:from:count:)`) and parsers (`parseGrepZ`, `parseBlamePorcelain`).
- **`Refs.swift`**: Repository ref/checkout models (`Worktree`, `Branch`, `PullRequest`), parsers (`parseWorktreeList`, `parseBranches`, `parsePullRequests`), `Git` extensions (`worktrees()`, `branches(comparedWith:)`, `hasCommit(_:)`, `fetchPullRequest(_:remote:)`, `searchCommits(_:limit:)`), and `listPullRequests(in:gh:path:)`.
- **`Review.swift`**: Review state specification (`Subject`, `Scope`, `Review`, `RevisionSpec`, `parseRevisionSpec`) and resolution (`ResolvedReview`, `Resolver.resolve`, `scoped(_:everything:commits:)`).
- **`WordDiff.swift`**: Intra-line UTF-16 token diffing (`wordTokens`, `wordDiff`, `pairChangedLines`), called by `FileState.wordRanges` (`Document.swift:398`) during `CodeView.color(row:_:)` (`CodeView.swift:345`) and `CodeView.landingColumn` (`CodeView.swift:879`).
- **`SearchPath.swift`**: Pure `PATH` extraction and deduplication (`pathVariable(inEnvironment:)`, `searchPath(shell:known:inherited:)`), called by `userPath()` and `loginShellPath` (`WindowActions.swift:804-828`).

### What Is in the Wrong Place or Duplicated
1. **Git plumbing split across `Explore.swift`, `Jump.swift`, and `Repository.swift`**:
   - `Jump.swift:109-184` defines `SnapshotBlob`, `SnapshotListing`, `Git.blobs(in:)`, `Git.listBlobs(in:)`, `Git.hashed(_:)`, `parseTree(_:)`, and `parseStaged(_:)`. Those belong in `Explore.swift` / `Parse.swift`.
   - `Repository.swift:147-158` implements `git status --porcelain=v1 -z` running and parsing directly in the UI target instead of `SextantCore`.
2. **Duplicate snapshot file listing pipelines (`Explore.swift:52-64` vs `Jump.swift:128-149`)**:
   - `Git.files(in:)` (`Explore.swift:52`) runs `ls-files -z --cached --others --exclude-standard --deduplicate` (plus a per-path `FileManager.fileExists` stat loop) or `ls-tree -r -z --name-only` to get `[String]` for the navigator and jump bar.
   - `Git.listBlobs(in:)` (`Jump.swift:128`) runs `ls-files -s -z` + `ls-files -z -m -o --exclude-standard` (plus another per-path `attributesOfItem` stat loop) or `ls-tree -r -z` to get `[(path, oid)]` for `DefinitionIndex`.
   - `ls-tree -r -z` and `ls-files -s -z` already contain both the paths and the modes/OIDs; running separate listings for `files(in:)` and `listBlobs(in:)` duplicates subprocesses and filesystem stats.
3. **Duplicate raw-change parsers (`Parse.swift:37-68` vs `Parse.swift:259-265`)**:
   - `parseRawPatchZ` parses `-z` NUL-terminated raw entries while `parseLog` / `parseRawLine` parses newline/tab-terminated C-quoted raw entries because `Git.log` (`Git.swift:119`) omits `-z`. Passing `-z` to `git log` eliminates `parseRawLine` and `unquoteGitPath` on log output entirely.
4. **Two different path sort orders (`Git.swift:195` vs git byte order)**:
   - `loadDiff` (`Git.swift:195`) sorts worktree/unstaged diffs with `localizedStandardCompare`, whereas non-worktree diffs (`.staged`, `.commit`, `.range`, `.stash`) return paths in git's UTF-8 byte order. Meanwhile `Jump.swift:126` sorts with `<` (UTF-8 byte order) and `RepoWindowController.swift:451` sorts `files(in:)` with `localizedStandardCompare` on the main actor.

### Unenforced Invariants
1. **No type distinction between a common-dir `Git` and a worktree `Git`**:
   - `Repository.git` is rooted at `commonDir` (e.g. `/path/to/repo/.git`, `Repository.swift:35`), while `ResolvedReview.git` is rooted at `commonDir` for `.branch`, `.pullRequest`, `.commit`, `.comparison`, `.stash` and at the worktree root only for `.worktree` (`Review.swift:115-122`).
   - Yet `Git` exposes worktree-only methods (`untrackedFiles`, `hashObjects`, `readWorktreeFile`, `worktreeMode`, `diff(.unstaged)`, `diff(.worktree)`, `files(in: .worktree)`, `blame(_, in: .worktree)`) on any `Git` instance. Calling a worktree operation on a `commonDir`-rooted `Git` fails with `fatal: this operation must be run in a work tree` or reads paths relative to `.git/`.
2. **`Review` allows invalid `(Subject, Scope)` pairs that `Resolver` fails to normalize (`Review.swift:46-58, 169, 175-189`)**:
   - `Resolver.resolve` (`Review.swift:169`) has `if case .commit = review.subject { review.scope = .everything }`, but does **not** normalize `.uncommitted`, `.staged`, or `.unstaged` scopes when `review.subject` is `.branch`, `.pullRequest`, `.comparison`, or `.stash`. If such a `Review` is passed to `Resolver.resolve`, `scoped()` returns `.worktree(since: nil)` / `.staged` / `.unstaged` with `runIn = repository.git` (`commonDir`), causing `res.git.diff(res.target)` to fail inside `.git`.
3. **`RawChange.oldOid` / `newOid` assumed to be blob OIDs everywhere**:
   - Nothing enforces that an OID in `RawChange` names a `blob` in the superproject's object database:
     - For submodules (`mode == "160000"`), `oldOid` and `newOid` are commit OIDs in the submodule repository (or `zeroOid` when the submodule checkout is dirty/moved in the worktree).
     - For unmerged files in `git diff --raw`, git emits combined raw format `::100644 100644 100644 <oid1> <oid2> <oid3> MM`, which `parseRawMeta` misparses so `oldOid` becomes `"100644"` (a mode string, not an OID!).
4. **`parseRawPatchZ` assumes a 1:1 positional match between `:raw` headers and `diff` patch blocks (`Parse.swift:70-91`)**:
   - `parseRawPatchZ` increments `pi += 1` without checking the path of `patches[pi]`. Whenever git emits a raw entry without a corresponding patch block (such as an unmerged `::...` entry in `git diff --raw -p -z`), every subsequent `FileDiff` is paired with the wrong file's `Hunk`s.
5. **Non-canonical `URL` roots across `Worktree`, `Subject.worktree(URL)`, and `Repository` dictionaries (`Refs.swift:32`, `Review.swift:28, 120-127`, `Repository.swift:31, 33, 120`)**:
   - `Resolver.resolve` matches `known = worktrees.first(where: { $0.root.standardizedFileURL == std })` (`Review.swift:123`), but constructs `runIn = Git(root: root, ...)` with the unstandardized `root` (`Review.swift:121`). `RepoWindowController` then indexes `repository.conflicts[res.git.root.path]` and `repository.uncommitted[res.git.root.path]` (`RepoWindowController.swift:380, 469`), which are keyed by `w.root.path` from `git worktree list`. Any symlink or non-standardized path difference causes a silent dictionary lookup miss.

### Fit with the Target Design (`scratch/perf/plan.md`)
- **Step 1 (Confirmed bugs)**: Fix CR preservation in `Parse.swift`, newline paths in `hashObjects`, `parseGrepZ` splitting on NUL records before LF, lazy untracked file reads instead of eager whole-file reads in `loadDiff`, plus the newly discovered bugs below (`oldLines` doubling added/unmerged files, `::` combined raw meta in `parseRawPatchZ`, `hashObjects` crashing on submodules/symlinks/nested repos, `\r\n` Swift `Character` splitting in `parseLog`/`CommitDetail.summary`, `parseBranches` dropping `*/HEAD`).
- **Step 2 (Limits & lifetimes)**: Enforce admission limits at the git/parse boundary (`ObjectReader` checking blob size in the `<oid> <type> <size>` header before reading/allocating; pipe output byte caps in `Git.run`; match count and line byte caps in `grep`/`parseGrepZ`; symlink `stat` vs `lstat` target size check in `readWorktreeFile`). Key `ObjectReader` by `commonDir`, close unused pipe fds, and bound its buffer capacity.
- **Step 4 (Refresh coordinator & process layer)**: Replace parked GCD threads in `Git.run` and `listPullRequests` with non-blocking readability/termination handlers and `withTaskCancellationHandler` so cancelled tasks terminate their child `git` process immediately. Pass `-c diff.autoRefreshIndex=false` and `--literal-pathspecs`. Consolidate `readRefs` into a single `for-each-ref` call with lazy cached ahead-behind.
- **Step 5 (Change fast paths)**: Cache `git log` commit lists by `(mergeBase, head)` OID pair so scope switches and worktree refreshes don't re-run `git log --raw -M -n 1000`. Use path-scoped diffs only when `status` reports plain modifications (`M`), falling back to full structural comparison on adds, deletes, renames, copies, typechanges, or unmerged entries.

---

## 2. Efficiency Summary

| Operation / Component | Current Work & Allocations | Complexity | Bottleneck / Waste |
| :--- | :--- | :--- | :--- |
| `Git.run` (`Git.swift:23-74`) | Spawns `Process`, parks 2–3 GCD threads (`readDataToEndOfFile` on stdout & stderr + `waitUntilExit`), buffers unbounded stdout `Data` | $O(\text{output bytes})$ | Ignores `priority` on outer `.userInitiated` / stderr `.default` queues; no `withTaskCancellationHandler` (cancelled tasks leave `git` running to completion); no output size cap. |
| `ObjectReader` (`Objects.swift:9-142`) | Serial `DispatchQueue`; 64 KB zero-filled `[UInt8]` per `read()` syscall; copies `buffer` -> `Array` (`read(count:)`) -> `Data(body.dropLast())` | $O(\text{blob bytes})$, 3x copy | 3x memory copy per blob; `buffer` never shrinks after a large blob; leaks 2 pipe fds per start; keyed by worktree `root` instead of `commonDir`; FIFO head-of-line blocking when background indexing queues hundreds of reads; reads oversized blobs in full before callers check size. |
| `parseRawPatchZ` (`Parse.swift:44-215`) | `[UInt8](data)` copies entire diff; `splitPatches` allocates `[ArraySlice<UInt8>]` for every line; `parseFilePatch` decodes every header and hunk line to `String` | $O(\text{diff bytes} + \text{lines})$ | Full copy of `Data` into `[UInt8]`; 24-byte `ArraySlice<UInt8>` per line (12 MB for 500k lines); allocates temporary 2-byte `[UInt8]` array on every `@`-starting line (`Parse.swift:165`). |
| `parseLog` (`Parse.swift:220-245`) | Decodes entire output to one `String`, then runs 4 nested `String`/`Substring.split(separator: Character)` passes | $O(\text{bytes})$ with high constant (Unicode grapheme segmentation) | **424.8 ms** for 1k commits x 100 files (12.4 MB); byte scanning takes **23.3 ms** (**18.3x faster**). Every 40-char OID (>15 bytes) is a heap-allocated `String`. |
| `parseBlamePorcelain` (`Explore.swift:21-48`) | Splits entire output on `0x0A` into `[Data.SubSequence]`; decodes every metadata line to `String`; allocates a new 40-char heap `String` OID on every line | $O(\text{lines} \times \text{line length})$ | **92.8 ms** and **+6.2 MB RSS** at 100k lines; byte scanning + interning OID per commit takes **19.9 ms** (**4.7x faster**) and avoids 100,000 heap `String` allocations. |
| `parseGrepZ` (`Explore.swift:7-20`) | Splits on `0x0A` then `0x00`; allocates `String` for `line` and `col` ints; allocates `p + ":"` per match; decodes unbounded line `text` | $O(\text{matches} \times \text{line length})$ | Decodes all matches (up to `200 * N_files`) and full minified lines before caller caps at 5,000 (`RepoWindowController.swift:1022`). |
| `wordDiff` + `wordRanges` (`WordDiff.swift:22-59`, `Document.swift:398-410`) | Converts lines to `[UInt16]`, tokenizes, allocates `(n+1)*(m+1)` `UInt16` DP table, runs full $O(n \cdot m)$ DP without prefix/suffix trimming; allocates 2 filtered `[UInt16]` arrays for unused `nonSpace` | $O(\sum_{\text{pairs}} n \cdot m)$ on **main thread** | Runs synchronously on main thread for **all** changed line pairs in the file when painting the first changed row, and runs **a second time** when `setWhole` resets `words = nil` (`Document.swift:127`). **281.8 ms** (single-token change) to **428.5 ms** (all-different) for 500 pairs of ~477-token lines; prefix/suffix trimming reduces 281.8 ms to **4.6 ms** (**61.6x faster**). |
| `Repository.readRefs` + `defaultBranch` (`Git.swift:102-108`, `Repository.swift:89-95`) | Runs `defaultBranch()` (up to 6 sequential `git` processes) *before* starting `worktrees()`, `branches()`, `stashes()` | Up to 9 `git` spawns per refresh | **22.3 ms** wasted in sequential `rev-parse` probes when `origin/HEAD` is absent; all ref and symref data is available from a single `for-each-ref`. |

---

## 3. Ranked Findings (Bugs, Slowness, Waste, Architecture)

*Note: Known findings already listed in `scratch/perf/plan.md` are omitted unless refined below with new root causes, failure modes, or benchmark measurements.*

---

### Finding 1 (Bug — High Impact): `git.diff(.unstaged)` corrupts metadata and shifts hunks onto the wrong files during a merge conflict
- **Location**: `Sources/SextantCore/Parse.swift:37-41`, `Parse.swift:56-91`, `Sources/SextantCore/Git.swift:142`
- **Category**: Bug
- **Plan Step**: Step 1 (Confirmed bugs) & Step 5 (Change fast paths)
- **Evidence**:
  When a repository has an unmerged path (`conflict.txt`) alongside a modified path (`z_normal.txt`), running `git diff` with `Git.diffFlags` (`--raw -p -z --no-abbrev ...`) for `Target.unstaged` outputs:
  ```text
  ::100644 100644 100644 94bbff0330dba67a16cbef761213fc9c627da559 5cea55df0c625b450296a877002c8c98fdd0cf85 0000000000000000000000000000000000000000 MM\0conflict.txt\0:100644 100644 ce013625030ba8dba906f756967f9e9ca394464a 0000000000000000000000000000000000000000 M\0z_normal.txt\0\0diff --git a/z_normal.txt b/z_normal.txt
  ```
  Two things go wrong simultaneously:
  1. In git's `combine-diff.c`, passing `--raw` to `git diff` causes unmerged paths to emit a 2-parent combined raw header starting with `::` (3 modes, 3 OIDs, status `MM`/`UU` at index 6) and **suppresses the `diff --cc` patch block** unless `--cc` is explicitly passed.
  2. `parseRawMeta` (`Parse.swift:37-41`) does `meta.dropFirst().split(separator: " ")` and reads `parts[0..4]`. On a `::` entry, `parts[0]` is `":100644"`, `parts[2]` (`oldOid`) is `"100644"`, `parts[3]` (`newOid`) is parent 1's OID, and `parts[4]` (`status`) is parent 2's 40-char hex OID (`5cea55df...`), so `status` becomes `'5'` (a hex digit, not `'U'`).
  3. In `parseRawPatchZ` (`Parse.swift:74-89`), because `c.status` is `'5'` (not `'U'`) and git emitted no patch for `conflict.txt`, `patches[0]` (`diff --git a/z_normal.txt b/z_normal.txt`) is assigned to `conflict.txt`, while `z_normal.txt` gets 0 hunks (`FileDiff(change: c)`). Every file after an unmerged entry shows another file's diff.
  - **Reproduction output from `GitAuditBench` (`[Test D]`)**:
    ```text
    [Test D - git.diff(.unstaged) during merge conflict]
      file=conflict.txt status=5 oldMode=:100644 oldOid=100644 hunks=1 firstHunkLines=["hello", "hello world"]
      file=z_normal.txt status=M oldMode=100644 oldOid=ce013625030ba8dba906f756967f9e9ca394464a hunks=0 firstHunkLines=[]
    ```
- **Fix**:
  1. In `parseRawMeta` / `parseRawPatchZ`, detect combined raw headers (`meta.hasPrefix("::")`, where the number of colons $k$ indicates $k$ parents, $k+1$ modes, $k+1$ OIDs, and status at `parts[2 * (k + 1)]`), normalize their status to `"U"`, and set `oldMode`/`newMode`/`oldOid`/`newOid` appropriately.
  2. Pass `--cc` in `Git.diffFlags` if combined patches are wanted for unmerged files, **and** match `PatchChunk` to `RawChange` by path (or track whether a raw entry has a patch) instead of blindly advancing `pi += 1`.

---

### Finding 2 (Bug — High Impact): `Git.diff` fails completely (`exit 128`) when the worktree contains a moved submodule, dangling symlink, symlink to a directory, or untracked nested git repository
- **Location**: `Sources/SextantCore/Git.swift:181-194`, `Git.swift:201-209`, `Sources/SextantCore/Jump.swift:136-154`
- **Category**: Bug (Refines known `hashObjects` finding with 4 concrete crash triggers)
- **Plan Step**: Step 1 (Confirmed bugs) & Step 2 (Lazy untracked reads)
- **Evidence**:
  In `Git.loadDiff` (`Git.swift:182-186`):
  ```swift
  let unhashed = files.indices.filter { files[$0].change.newOid == zeroOid && !files[$0].change.isDeleted }
  let extra = try await untracked
  let paths = unhashed.map { files[$0].change.path } + extra
  if !paths.isEmpty {
      let hashes = try await hashObjects(paths)
  ```
  `hashObjects` runs `git hash-object --stdin-paths`, which terminates with exit status `128` (throwing `GitError` and aborting the entire `git.diff()` call with an error screen) if **any** path in `paths` cannot be opened and hashed as a regular file:
  1. **Unstaged submodule commit change or dirty submodule (`newMode == "160000"`)**: `git diff --raw` emits `:160000 160000 <old> 0000000000000000000000000000000000000000 M\0submod\0`. Because `newOid == zeroOid && !isDeleted`, `loadDiff` passes `"submod"` (a directory) to `git hash-object --stdin-paths`, which exits 128: `fatal: Unable to hash submod`.
  2. **Untracked nested git repository**: `git ls-files --others --exclude-standard -z` emits `"nested-repo/\0"` (a directory with a trailing slash). `hashObjects` exits 128: `fatal: Unable to hash nested-repo/`.
  3. **Dangling symlink (tracked or untracked)**: `git hash-object --stdin-paths` calls `open()` (following symlinks) instead of hashing the link target path, and exits 128: `fatal: could not open 'dangling.lnk' for reading: No such file or directory`.
  4. **Symlink to a directory (tracked or untracked)**: `git hash-object --stdin-paths` follows the symlink to the directory and exits 128: `fatal: Unable to hash dirlink`.
  5. **File deleted concurrently between `git diff`/`ls-files` and `hash-object`**: `git hash-object --stdin-paths` exits 128 and aborts even after all 4 retry iterations in `Git.diff`.
  - **Reproduction output from `GitAuditBench` (`[Test E1–E3]`)**:
    ```text
    [Test E1 - dangling symlink in worktree] THREW: fatal: could not open 'dangling.lnk' for reading: No such file or directory
    [Test E2 - symlink to directory in worktree] THREW: fatal: Unable to hash dirlink
    [Test E3 - untracked nested git repo in worktree] THREW: fatal: Unable to hash nested-repo/
    ```
- **Fix**:
  - Never pass gitlinks (`newMode == "160000"`), directories (`path.hasSuffix("/")` or non-regular files), or symlinks (`newMode == "120000"`) to `git hash-object --stdin-paths`.
  - For symlinks (`120000`), compute the git blob ID in-process from `readlink` bytes (`blobID(of: Data(dest.utf8))`), which also matches what git records when staging/committing the symlink (unlike `hash-object --stdin-paths`, which hashes the target file's contents).
  - With Step 2's lazy untracked loading and Step 6's in-process hashing of exact analyzed bytes (`blobID(of:)`), `loadDiff` does not need to spawn `git hash-object --stdin-paths` during diff loading at all.

---

### Finding 3 (Bug — High Impact): `Git.oldLines(of:)` returns new-side lines when `oldOid == zeroOid`, causing `wholeFile` to duplicate the entire file on added and unmerged files
- **Location**: `Sources/SextantCore/Git.swift:225-230`, `Sources/SextantCore/Parse.swift:203-211`, `Sources/SextantCore/WholeFile.swift:7-28`, `Sources/SextantApp/Repository.swift:247-248`
- **Category**: Bug + Waste
- **Plan Step**: Step 1 (Confirmed bugs)
- **Evidence**:
  Look at `Git.oldLines(of:)` (`Git.swift:225-230`):
  ```swift
  public func oldLines(of file: FileDiff) async throws -> [String] {
      let c = file.change
      if c.oldOid != zeroOid { return splitLines(try await blob(c.oldOid)) }
      if c.newOid != zeroOid, let d = try? await blob(c.newOid) { return splitLines(d) }
      return splitLines(readWorktreeFile(c.path) ?? Data())
  }
  ```
  When `c.oldOid == zeroOid` (an added file, untracked file, copied/typechanged file without old blob, or unmerged file), `oldLines(of:)` falls back to reading `c.newOid` or the worktree file—returning the **new** file's lines as `oldLines`!
  When those lines are passed to `wholeFile(file.hunks, oldLines: old)` (`WholeFile.swift:7-28`):
  1. **Added / untracked file in `Repository.open` (`Repository.swift:247-248`) or multi-hunk/noted added file**:
     The hunk has `oldStart = 0, oldCount = 0` and $N$ `.added` lines (`oldNo = 0, newNo = 1...N`). After the hunk loop, `nextOld` is still `1`, so `context(through: old.count)` at `WholeFile.swift:26` appends all $N$ lines of `old` **a second time** as `.context` lines (`oldNo = 1...N, newNo = N+1...2N`).
  2. **Unmerged file with combined diff (`diff --cc`, `status == "U"`)**:
     In `parseFilePatch` (`Parse.swift:203-211`), when `prefixWidth > 1`, every `DiffLine` (including `.context` and `.deleted`) is created with `oldNo: 0`. In `FileState.init` (`Document.swift:56`), `isWhole` is `false` because `status == "U"` is neither `isAdded` nor `isDeleted`. When opened in the reader (`Document.prepareWhole`, `Document.swift:149-150`), `oldLines(of:)` reads the conflicted worktree file as `oldLines`, and `wholeFile` sees `l.oldNo == 0` for every hunk line, leaving `nextOld = 1` and appending the entire worktree file a second time after the conflict hunk!
  - **Reproduction output from `GitAuditBench` (`[Test F]` & `[Test H]`)**:
    ```text
    [Test F - oldLines(of:) + wholeFile on added 3-line file (as Repository.open does)]
      hunk lines count: 3
      oldLines returned count: 3 (expected 0!)
      wholeFile lines count: 6 (expected 3, got 6: ["added:line1", "added:line2", "added:line3", "context:line1", "context:line2", "context:line3"])
    [Test H - Combined diff (diff --cc) + wholeFile]
      parsed hunk lines oldNo: [0, 0, 0, 0, 0, 0] (all 0!)
      wholeFile texts: ["context:line1", "added:<<<<<<< HEAD", "added:main2", "added:=======", "added:other2", "added:>>>>>>> other", "context:line1", "context:main2", "context:line3", "context:line4"]
    ```
- **Fix**:
  - In `Git.oldLines(of:)` (`Git.swift:225-230`), if `c.oldOid == zeroOid` or `c.oldMode == "160000"` or `c.oldMode == "120000"`, return `[]` immediately. Never return `newOid` or `readWorktreeFile` as `oldLines`.
  - In `Repository.open` (`Repository.swift:247`), skip calling `oldLines` / `wholeFile` when `first.change.isAdded || first.change.isDeleted || first.hunks.isEmpty` (since `FileState.init` already marks it `isWhole = true`).
  - In `parseFilePatch` (`Parse.swift:203-211`), track `oldNo` for parent 1 in combined diffs (incrementing `oldNo` when the first prefix column is `' '` or `'-'`) so `wholeFile` and `unchangedLinesBefore` use consistent parent-1 coordinates.

---

### Finding 4 (Slowness + Bug — High Impact): `parseLog` uses `String.split(separator: Character)` 4 levels deep, costing 425 ms on 1k commits (18.3x slower than byte scan) and breaking on `\r\n`
- **Location**: `Sources/SextantCore/Parse.swift:220-245`, `Sources/SextantCore/Model.swift:66`, `Sources/SextantCore/Review.swift:145, 160`
- **Category**: Slowness + Bug + Waste
- **Plan Step**: Step 1 (Confirmed bugs) & Step 5 (Cached commit lists)
- **Evidence**:
  1. **Unicode grapheme cluster segmentation overhead (`Parse.swift:220-231, 259-265`)**:
     `parseLog` decodes the entire `git log --raw` `Data` into a `String`, then splits by `Character("\u{1e}")` -> `Character("\n")` -> `Character("\t")` -> `Character(" ")`. In Swift's standard library, `String.split(separator: Character)` runs the Unicode extended-grapheme-cluster segmentation state machine across every byte.
     In `GitAuditBench` (`=== 2. parseLog Scaling ===`), parsing 1,000 commits (`Resolver.resolve`'s hardcoded `count: 1000` at `Review.swift:145, 160`):
     - 100 commits, 10 files/commit (136 KB): **4.72 ms** current vs **0.28 ms** UTF-8 byte scan (**17.0x speedup**)
     - 1,000 commits, 10 files/commit (1.36 MB): **46.77 ms** current vs **2.72 ms** UTF-8 byte scan (**17.2x speedup**)
     - 1,000 commits, 50 files/commit (6.28 MB): **213.93 ms** current vs **11.84 ms** UTF-8 byte scan (**18.1x speedup**)
     - 1,000 commits, 100 files/commit (12.43 MB): **424.77 ms** current vs **23.26 ms** UTF-8 byte scan (**18.3x speedup**)
  2. **CRLF (`\r\n`) bug in `parseLog` (`Parse.swift:224`) and `CommitDetail.summary` (`Model.swift:66`)**:
     Because Swift treats `"\r\n"` as a single `Character` (`"\r\n" != "\n"`), calling `.split(separator: "\n")` on a `String` or `Substring` fails to split at CRLF boundaries:
     - In `CommitDetail.summary` (`Model.swift:66`), `message.split(separator: "\n", maxSplits: 1).first` on a commit message with CRLF line endings returns the **entire multi-line commit message** instead of the first line (`[Test A1]`).
     - In `parseLog` (`Parse.swift:224`), `record.split(separator: "\n")` when a commit header ends with `\r\n` fails to split the header from the `:100644 ...` raw line, concatenating the raw change line into `Commit.subject` and dropping `Commit.changes` (`[Test A2]`).
  3. **Unnecessary `--raw -M` work in `Git.history` (`Explore.swift:96-99`) and repeated `git.log` in `Resolver.resolve` (`Review.swift:145, 160`)**:
     - `Git.history(of:from:count:)` passes `--raw --no-abbrev -M`, forcing git to compute tree diffs and rename detection for 100 commits even though its only caller (`WindowActions.showFileHistory`, `WindowActions.swift:383`) never reads `Commit.changes` (and `openHistoryCommit` at `WindowActions.swift:402` opens the current `path` rather than the historical path before a rename).
     - `Resolver.resolve` re-runs `git.log("\(mergeBase)..\(head)", skip: 0, count: 1000)` on every refresh and every commit-scope step in the navigator.
- **Fix**:
  - Pass `-z` to `git log` and parse `parseLog` directly over `Data` / `UnsafeBufferPointer<UInt8>` splitting on ASCII bytes (`0x1E`, `0x0A`, `0x1F`, `0x00`), stripping optional `0x0D` (`\r`).
  - Fix `CommitDetail.summary` (`Model.swift:66`) to split with `whereSeparator: \.isNewline` (which matches `\n`, `\r`, and `\r\n`).
  - Cache `commits` in `Repository` / refresh coordinator keyed by `(mergeBase, head)` OID pair (Step 5).

---

### Finding 5 (Slowness + Bug — High Impact): `wordDiff` runs full $O(n \cdot m)$ DP on the main thread without trimming common prefix/suffix (up to 428 ms hang per file, computed twice) and false-matches unrelated indented lines
- **Location**: `Sources/SextantCore/WordDiff.swift:22-59`, `Sources/SextantApp/Document.swift:127, 398-410`, `Sources/SextantApp/CodeView.swift:345`
- **Category**: Slowness + Bug + Waste
- **Plan Step**: Step 1 (Confirmed bugs) & Step 3 (Cheap UI fast paths)
- **Evidence**:
  1. **Main-thread whole-file computation on first visible changed row, repeated on `setWhole`**:
     When `CodeView.color(row:_:)` (`CodeView.swift:345`) renders the first visible changed row of a file, it calls `f.wordRanges(row.line)` (`Document.swift:398`) on the **main thread**. When `f.words == nil`, `wordRanges` runs `wordDiff` across **every** pair of changed lines in the entire file, not just visible rows. Then, when `adoptWhole()` calls `setWhole()` (`Document.swift:127`), `words = nil` wipes the cache and forces the main thread to recompute `wordDiff` for the entire file a second time!
  2. **No common token prefix/suffix stripping (`WordDiff.swift:25-33`)**:
     `wordDiff` allocates a `(n + 1) * (m + 1)` `UInt16` DP table and runs the nested loop over all $n \times m$ token pairs even when 99% of tokens on the line are identical.
     Furthermore, because `guard n * m <= 250_000` (`WordDiff.swift:26`) is checked *before* stripping common prefix/suffix tokens, any line with >500 tokens (~250 dot-separated identifiers, ~1,100 chars—well below `Document.swift:403`'s `< 2000` UTF-16 limit) returns `nil` and gets **no word-diff highlighting** even when only 1 token changed.
     - **Benchmark numbers from `GitAuditBench` (`=== 6. wordDiff Scaling ===`)**:
       - 100 pairs, 37 tokens/line (96 UTF-16): **0.50 ms** current vs **0.12 ms** trimmed (**4.2x speedup**)
       - 1,000 pairs, 37 tokens/line (96 UTF-16): **5.54 ms** current vs **1.39 ms** trimmed (**4.0x speedup**)
       - 500 pairs, 197 tokens/line (574 UTF-16): **51.44 ms** current vs **2.13 ms** trimmed (**24.1x speedup**)
       - 500 pairs, 477 tokens/line (1,452 UTF-16): **281.76 ms** current vs **4.57 ms** trimmed (**61.6x speedup**)
       - 500 pairs, 479 tokens/line (all-different): **428.54 ms** on main thread just to return `nil`!
  3. **Unused `nonSpace` filter allocations and indentation false-positive bug (`WordDiff.swift:44-45`)**:
     ```swift
     let nonSpace = max(ua.filter { $0 != 32 && $0 != 9 }.count, ub.filter { $0 != 32 && $0 != 9 }.count)
     guard nonSpace > 0, Double(common) / Double(max(ua.count, ub.count)) >= 0.35 else { return nil }
     ```
     `ua.filter` and `ub.filter` allocate two temporary `[UInt16]` arrays on every `wordDiff` call, only to check `nonSpace > 0` while dividing `common` (which includes matched whitespace tokens!) by `max(ua.count, ub.count)`. As shown in `[Test B]`:
     - Old: `"                return foo(1)"` (16 spaces + 13 chars)
     - New: `"                throw bar(2)"` (16 spaces + 12 chars)
     Because the 16 leading spaces match (`common = 18`, `18 / 29 = 62% >= 35%`), `wordDiff` returns intra-line highlights for two completely unrelated statements that merely share indentation!
- **Fix**:
  - Strip common prefix and suffix tokens in `wordDiff` before checking `nMid * mMid <= 250_000` and allocating `dp`.
  - Exclude whitespace tokens (`cls == 1`) from `common` and divide by `nonSpace` (counted without allocating filtered arrays) so leading indentation does not trigger false-positive word diffs.
  - Compute `wordRanges` lazily per changed hunk/run or off the main thread during `FileState.analyze`, and preserve or remap `words` across `setWhole`.

---

### Finding 6 (Waste + Slowness + Bug — High Impact): `Git.run` ignores task cancellation, leaving superseded `git` processes running to completion, and ignores `priority` on GCD queues
- **Location**: `Sources/SextantCore/Git.swift:23-74`, `Sources/SextantCore/Refs.swift:139-154, 164-183`
- **Category**: Waste + Slowness (Refines `Git.run` finding in `plan.md`)
- **Plan Step**: Step 2 (Limits & lifetimes) & Step 4 (Refresh coordinator)
- **Evidence**:
  1. **`withCheckedThrowingContinuation` without `withTaskCancellationHandler` (`Git.swift:24`)**:
     When a Swift `Task` calling `Git.run` is cancelled (e.g., `RepoWindowController.refreshTask?.cancel()` on `RepoWindowController.swift:852`, `SubjectPicker.searchTask?.cancel()` on `SubjectPicker.swift:181`, or a superseded file load/search), the spawned `Process` is **never terminated**. Even worse, because `withCheckedThrowingContinuation` cannot resume until `p.waitUntilExit()` finishes, structured-concurrency `async let` scopes (such as `loadDiff` in `Git.swift:178-179`, `searchCommits` in `Refs.swift:141-144`, `lookUp` in `DefinitionIndex.swift:35-36`) block awaiting the un-terminated child process.
     - In `SubjectPicker` (`Refs.swift:139-154`), each keystroke after 150 ms spawns 2–4 `git log --branches --remotes --tags -i --fixed-strings --grep=... / --author=...` processes. Typing 5 characters cancels the previous Swift tasks but leaves up to 10–20 full-repo `git log` processes running concurrently.
     - **Reproduction output from `GitAuditBench` (`[Test K]`)**:
       ```text
       [Test K - Git.run cancellation] Task cancelled at 25 ms, but Git.run did not terminate subprocess and waited 520.39 ms until process exit
       ```
  2. **QoS priority inversion (`Git.swift:24, 51, 59`)**:
     `Git.run` accepts `priority: QualityOfService = .userInitiated`, sets `p.qualityOfService = priority`, but dispatches the outer block onto `DispatchQueue.global(qos: .userInitiated)` (hardcoded) and the stdin/stderr blocks onto `DispatchQueue.global()` (`.default` QoS), regardless of `priority`.
  3. **Unbounded stdout buffering (`Git.swift:63`)**:
     `out.fileHandleForReading.readDataToEndOfFile()` buffers the entire process output in memory with no byte limit before returning.
- **Fix**:
  - Wrap `Git.run` in `withTaskCancellationHandler`, storing a locked/atomic reference to `Process` so `onCancel` calls `p.terminate()` (closing stdout/stderr pipes to break any blocked read) immediately when the Swift `Task` is cancelled.
  - Use `terminationHandler` + non-blocking dispatch I/O or `FileHandle.readabilityHandler` with an output byte limit (terminating the process and throwing an admission limit error if stdout exceeds the cap), eliminating the 2–3 parked GCD threads per process.

---

### Finding 7 (Waste + Bug — High Impact): `ObjectReader` leaks 2 file descriptors per process start, copies every blob 3x through an unshrinking `[UInt8]` buffer, reads oversized blobs before size checks, and suffers FIFO head-of-line blocking
- **Location**: `Sources/SextantCore/Objects.swift:9-142`, `Sources/SextantCore/DefinitionIndex.swift:66`, `Sources/SextantApp/RepoWindowController.swift:560`
- **Category**: Waste + Slowness + Bug (Refines `ObjectReader` finding in `plan.md`)
- **Plan Step**: Step 2 (ObjectReader lifetime & admission limits) & Step 7 (Measured reader pool)
- **Evidence**:
  1. **File descriptor leak on `dup()` (`Objects.swift:77-86`)**:
     ```swift
     let inPipe = Pipe(), outPipe = Pipe()
     p.standardInput = inPipe
     p.standardOutput = outPipe
     ...
     input = dup(inPipe.fileHandleForWriting.fileDescriptor)
     output = dup(outPipe.fileHandleForReading.fileDescriptor)
     ```
     Because `p` retains `inPipe` and `outPipe` (and `self.process = p` retains `p`), `inPipe.fileHandleForWriting` and `outPipe.fileHandleForReading` are never closed after `dup()`. Every `ObjectReader` holds **4 open fds instead of 2**, and calling `close(input)` in `stop()` does not close the write end of stdin until `p` is deallocated.
     - **Verified in `GitAuditBench` (`[Test I1]`)**:
       ```text
       open fds before first blob read: 7, after first blob read: 11 (delta = +4, expected +2 pipes, actual +4 due to dup without closing Pipe fds)
       ```
  2. **3x memory copy + 64 KB per-read zero-fill + unbounded `buffer` retention (`Objects.swift:64-65, 109-141`)**:
     - `fill()` allocates a zero-filled `[UInt8](repeating: 0, count: 65536)` on every `Foundation.read` syscall and appends `chunk[..<n]` to `buffer: [UInt8]`.
     - `read(count: size + 1)` copies `Array(buffer[position..<position + count])` (copy #2).
     - `read(_ name:)` copies `Data(body.dropLast())` (copy #3).
     - After reading a large blob (e.g. 10 MB), `buffer.removeFirst(position)` in Swift keeps the backing array capacity, retaining the multi-MB buffer for the lifetime of the app.
  3. **No admission size check on the `<oid> blob <size>` header (`Objects.swift:62-65`)**:
     `git cat-file --batch` prints `<oid> <type> <size>\n` before the body bytes. Yet `ObjectReader` has no `limit` parameter: when `DefinitionIndex.tagged` (`DefinitionIndex.swift:66`) indexes a commit or index containing a 100 MB blob, `git.blob(oid:)` reads and copies all 100 MB (allocating 300 MB across the 3 copies) only for `DefinitionIndex.parseable` (`DefinitionIndex.swift:92`) to reject `data.count <= largestFile` (1 MB) and discard it! Similarly, `git.contents(of: path, in: .commit(c))` (`Explore.swift:69`) has **no size limit at all** (unlike `.worktree` which caps at 4 MB).
  4. **FIFO head-of-line blocking (`Objects.swift:12, 46-56`)**:
     All callers (`DefinitionIndex.definitions` spawning `activeProcessorCount - 2` workers, `prepareNeighbors`, and interactive file opens) share one FIFO `DispatchQueue`. In `[Test I3]`, queuing 200 small 16 KB reads delayed a single interactive 16 KB read by **7.96 ms** (and with larger 100 KB–1 MB blobs, by **50–150+ ms**).
- **Fix**:
  - Do not `dup()` without closing `inPipe.fileHandleForWriting` / `outPipe.fileHandleForReading` (or use `inPipe.fileHandleForWriting.fileDescriptor` directly while `process` is alive).
  - Allocate a single `Data(count: size)` when `fields[1] == "blob"` and `size <= limit`, copy any unread bytes from a fixed 64 KB ring/scratch buffer into `Data`, and `Foundation.read` the remainder directly into `Data.withUnsafeMutableBytes` (1 allocation, 0 extra copies, 0 retained buffer growth). If `size > limit` or `fields[1] != "blob"`, drain `size + 1` bytes into the fixed 64 KB scratch buffer and return `nil`.
  - Key `ObjectReader` by `commonDir` (not worktree `root`), and either prioritize interactive reads ahead of background indexing or use a small reader pool (Step 7).

---

### Finding 8 (Bug — Medium-High Impact): `readWorktreeFile` uses `lstat` (`attributesOfItem`) for its 4 MB size check, then `Data(contentsOf:)` follows symlinks and reads arbitrarily large target files
- **Location**: `Sources/SextantCore/Git.swift:219-223`, `Sources/SextantCore/Explore.swift:59-62`
- **Category**: Bug (Admission-limit bypass & symlink mishandling)
- **Plan Step**: Step 1 (Confirmed bugs) & Step 2 (Admission limits)
- **Evidence**:
  In `Git.readWorktreeFile` (`Git.swift:219-223`):
  ```swift
  public func readWorktreeFile(_ path: String, limit: Int = 4 << 20) -> Data? {
      let url = root.appendingPathComponent(path)
      guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attrs[.size] as? Int, size <= limit else { return nil }
      return try? Data(contentsOf: url)
  }
  ```
  `FileManager.default.attributesOfItem(atPath:)` calls `lstat(2)`. When `path` is a symbolic link pointing to a 5 MB (or 500 MB) file:
  - `attrs[.type]` is `.typeSymbolicLink` and `attrs[.size]` is the length of the link target path string (e.g. `7` bytes for `"big.bin"`), which easily passes `size <= limit` (`7 <= 4_194_304`).
  - `Data(contentsOf: url)` then calls `open(2)` **following the symlink** and reads the entire 5 MB / 500 MB target file into memory!
  - Furthermore, for a tracked or staged symlink in git (`mode 120000`), git stores the symlink destination path string (`readlink`) as the blob content, whereas `readWorktreeFile` returns the pointed-to file's contents.
  - **Reproduction output from `GitAuditBench` (`[Test G]`)**:
    ```text
    [Test G - Symlink bypassing 4MB limit in readWorktreeFile]
      directRead of 5MB file (limit 4MB): -1 bytes (nil expected)
      symlinkRead of link to 5MB file (limit 4MB): 5242880 bytes (bypassed 4MB limit!)
    ```
  - Conversely, in `Git.files(in: .worktree)` (`Explore.swift:61`), `fm.fileExists(atPath:)` uses `stat(2)` (following symlinks), so a valid tracked symlink whose target does not currently exist on disk is treated as non-existent and removed from the file list!
- **Fix**:
  - In `readWorktreeFile`, check `attrs[.type]`: if `.typeSymbolicLink`, return `Data((try? FileManager.default.destinationOfSymbolicLink(atPath: url.path))?.utf8 ?? "".utf8)` (matching git's `120000` blob representation); only read `Data(contentsOf: url)` when `attrs[.type] == .typeRegular && size <= limit`.
  - In `Git.files(in: .worktree)`, instead of calling `fm.fileExists(atPath:)` on all $N$ repository paths, subtract worktree-deleted tracked files (`git ls-files -z -d`) so tracked symlinks are preserved and $N$ `stat()` syscalls are eliminated.

---

### Finding 9 (Slowness + Memory — Medium-High Impact): `parseBlamePorcelain` allocates a new 40-byte heap `String` OID on every line and decodes all metadata lines (92.8 ms and +6.2 MB RSS at 100k lines; 4.7x faster with byte scan + OID interning)
- **Location**: `Sources/SextantCore/Explore.swift:21-48`, `Sources/SextantCore/Model.swift:175-189`
- **Category**: Slowness + Waste
- **Plan Step**: Step 2 (Limits) & Step 6/7
- **Evidence**:
  In `parseBlamePorcelain` (`Explore.swift:21-48`):
  - `data.split(separator: 0x0A, omittingEmptySubsequences: false)` allocates a `[Data.SubSequence]` array with 2–12 elements per line of the blamed file (200k–400k slices for a 100k-line file).
  - For every header line, `let s = String(decoding: raw, as: UTF8.self)` decodes the line to a `String`, and `current = String(s[..<sp])` allocates a **fresh 40-byte heap `String`** (exceeding Swift's 15-byte Small String limit) even when `commits[current]` already exists!
  - For every non-tab metadata line (`author-mail`, `author-tz`, `committer*`, `filename`, `previous`, `boundary`), `let s = String(decoding: raw, as: UTF8.self)` allocates a `String` even when `commits[current] != nil` or the key is unused.
  - **Benchmark numbers from `GitAuditBench` (`=== 3. parseBlamePorcelain Scaling ===`)**:
    - 1,000 lines (115 KB): **0.97 ms** current vs **0.24 ms** byteScan+intern (**4.0x speedup**)
    - 10,000 lines (1.08 MB): **9.18 ms** current vs **2.09 ms** byteScan+intern (**4.4x speedup**)
    - 100,000 lines (11.07 MB): **92.80 ms** (+6,224 KB RSS) current vs **19.93 ms** byteScan+intern (**4.7x speedup**)
- **Fix**:
  - Scan `Data` in a single pass via `withUnsafeBytes` without building `data.split(separator: 0x0A)`, reuse the existing `oid` `String` from `commits[oid]` (or store `commits: [Blame.Commit]` and `lines: [Int32]` indices into `commits`, reducing `lines` memory from 16 bytes + 64-byte heap string per line to 4 bytes per line!), and skip metadata lines when `commits[current]` is already populated.

---

### Finding 10 (Waste + Slowness — Medium Impact): `Git.defaultBranch()` runs up to 6 sequential `git` processes before `Repository.readRefs` starts `worktrees()`, `branches()`, and `stashes()`
- **Location**: `Sources/SextantCore/Git.swift:102-108`, `Sources/SextantApp/Repository.swift:89-95`
- **Category**: Waste + Slowness
- **Plan Step**: Step 4 (Refresh coordinator)
- **Evidence**:
  In `Repository.readRefs` (`Repository.swift:89-95`):
  ```swift
  nonisolated static func readRefs(_ git: Git) async -> Refs {
      let base = await git.defaultBranch()
      async let worktrees = git.worktrees()
      async let branches = git.branches(comparedWith: base)
      async let stashes = git.stashes()
      return await Refs(base: base, worktrees: worktrees, branches: branches, stashes: stashes)
  }
  ```
  And in `Git.defaultBranch()` (`Git.swift:102-108`):
  ```swift
  public func defaultBranch() async -> String? {
      if let r = await optionalString(["symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD"]) { return r }
      for b in ["main", "master", "trunk", "origin/main", "origin/master"] {
          if await optionalString(["rev-parse", "--verify", "-q", b + "^{commit}"]) != nil { return b }
      }
      return nil
  }
  ```
  When `refs/remotes/origin/HEAD` is not set (common in local repos, repos without a remote named `origin`, or fresh clones where `origin/HEAD` wasn't created), `defaultBranch()` spawns up to **6 sequential `git` subprocesses** (`symbolic-ref`, then `rev-parse` for `main`, `master`, `trunk`, `origin/main`, `origin/master`) before `worktrees()`, `branches()`, and `stashes()` are even launched!
  - **Benchmark numbers from `GitAuditBench` (`[Test J1]`)**:
    In a local repo on a feature branch (e.g. `develop`), `defaultBranch()` alone takes **22.31 ms** across 6 sequential `git` spawns on every refresh.
- **Fix**:
  - Once `ahead-behind` is made lazy/cached (Step 4), `branches()` no longer depends on `base`. Include `%(symref:short)` in `git for-each-ref` over `refs/heads refs/remotes` and derive `defaultBranch` in memory from the `for-each-ref` result (`refs/remotes/origin/HEAD`'s symref target if present, else the first of `["main", "master", "trunk", "origin/main", "origin/master"]` present in the returned ref set) in **0 extra subprocesses**.

---

### Finding 11 (Bug — Medium Impact): `parseBranches` silently drops any local or remote branch whose name ends with `/HEAD`, and `searchCommits` buries or drops exact SHA matches behind newer `--grep` matches
- **Location**: `Sources/SextantCore/Refs.swift:71-88`, `Refs.swift:139-154`
- **Category**: Bug
- **Plan Step**: Step 1 (Confirmed bugs) & Step 4 (Refresh coordinator)
- **Evidence**:
  1. **`parseBranches` (`Refs.swift:83`)**:
     ```swift
     guard ref.hasPrefix("refs/heads/") || isRemote, !name.hasSuffix("/HEAD") else { return nil }
     ```
     To filter out symbolic refs like `refs/remotes/origin/HEAD`, `parseBranches` rejects any branch where `name.hasSuffix("/HEAD")`. Consequently, a legitimate branch named `refs/heads/fix/HEAD` (`name = "fix/HEAD"`) or `refs/remotes/origin/fix/HEAD` is **silently dropped** (`[Test C]`: `expected count: 1, actual count: 0`), while a non-`HEAD` symbolic ref is not filtered out.
  2. **`searchCommits` (`Refs.swift:146-153`)**:
     ```swift
     if q.count >= 4, q.allSatisfy(\.isHexDigit), let oid = await resolve(q), let d = try? await run(["log", "--format=" + logFormat, "-n", "1", oid]) {
         out += parseLog(d)
     }
     out += parseLog(await byText ?? Data()) + parseLog(await byAuthor ?? Data())
     var seen = Set<String>()
     return out.filter { seen.insert($0.oid).inserted }.sorted { $0.date > $1.date }.prefix(limit).map { $0 }
     ```
     When the user pastes a commit hash prefix (e.g. a 7-char SHA of an older commit), `resolve(q)` finds the exact commit and places it at `out[0]`. Then `.sorted { $0.date > $1.date }.prefix(limit)` re-sorts all results strictly by commit date, pushing the exact SHA match behind up to `limit` newer commits whose message or author matched `q` (or dropping it completely if `byText` + `byAuthor` returned `limit` newer commits!).
- **Fix**:
  - In `branchFormat` (`Refs.swift:71`), include `%(symref)` and filter out branches where the `symref` field is non-empty instead of `!name.hasSuffix("/HEAD")`.
  - In `searchCommits` (`Refs.swift:153`), keep the exact `resolve(q)` OID match pinned at index 0 ahead of the date-sorted `--grep` and `--author` matches.

---

### Finding 12 (Bug + Architecture — Medium Impact): `Resolver.resolve` silently falls back to diffing only the tip commit (`.commit(head)`) or diffing against `emptyTreeOid` when `mergeBase` is `nil` or `oldest` is beyond the 1,000-commit log window
- **Location**: `Sources/SextantCore/Review.swift:155-189`
- **Category**: Bug + Architecture
- **Plan Step**: Step 4 (Refresh coordinator) & Step 5 (Change fast paths)
- **Evidence**:
  1. **Silent fallback to `.commit(h)` when `mergeBase` is `nil` (`Review.swift:163-167`)**:
     ```swift
     let everything: Target = switch review.subject {
     case .worktree: .worktree(since: mergeBase)
     case .commit(let c): .commit(c)
     default: head.map { h in mergeBase.map { .range(base: $0, head: h) } ?? .commit(h) } ?? .worktree(since: nil)
     }
     ```
     When reviewing `.branch(name)` or `.pullRequest(n)` with a `base` (e.g. `"origin/main"`) where `git.mergeBase(base, head)` returns `nil` (because `base` was deleted/renamed or shares no common ancestor with `head`), `mergeBase` is `nil` and `everything` silently becomes `.commit(h)`—showing only the single tip commit of the branch instead of reporting that `base` could not be compared! (Contrast this with `.comparison(..., sinceAncestor: true)` on `Review.swift:141`, which properly throws `GitError(message: "‘\(from)’ and ‘\(to)’ have no common ancestor")`.)
  2. **Silent fallback to `emptyTreeOid` in `scoped` (`Review.swift:185-187`)**:
     ```swift
     case .commits(let newest, let oldest):
         if newest == oldest { return .commit(newest) }
         let parent = commits.first { $0.oid == oldest }?.parents.first ?? emptyTreeOid
         return .range(base: parent, head: newest)
     ```
     If `oldest` is not found in `commits` (e.g. because `commits` is truncated at `count: 1000` or the branch was rebased so `oldest` is no longer in `commits`), `commits.first { $0.oid == oldest }` is `nil` and `parent` defaults to `emptyTreeOid`—diffing `newest` against an empty tree (showing every file in the repository as newly added) instead of resolving `oldest^1`!
  3. **Redundant `resolve(c + "^1")` subprocess on every single-commit diff (`Git.swift:152-154` vs `Review.swift:185`)**:
     When `newest == oldest`, `scoped` returns `.commit(newest)`, and `Git.diffArgs(.commit(c))` spawns `await resolve(c + "^1")` even when `commits` already has `c.parents.first` in memory.
- **Fix**:
  - When `review.subject` is `.branch` or `.pullRequest` and `review.base != nil` but `mergeBase == nil`, throw a descriptive `GitError` (just as `.comparison` does) rather than silently showing `.commit(head)`.
  - In `scoped(.commits(newest, oldest), ...)`, if `oldest` is in `commits`, use `oldestCommit.parents.first ?? emptyTreeOid` (even when `newest == oldest` if `oldest` is in `commits`, returning `.range(base: parent, head: newest)` to avoid the extra `resolve(c + "^1")` subprocess in `diffArgs`); if `oldest` is not in `commits`, resolve `oldest + "^1"` in `Resolver`.

---

### Finding 13 (Waste — Medium Impact): `Git.blobs(in: .worktree)` hashes every modified and untracked file in the worktree via `git hash-object` before `DefinitionIndex` filters by supported language or file size
- **Location**: `Sources/SextantCore/Jump.swift:124-154`, `Sources/SextantCore/DefinitionIndex.swift:22, 58-70`
- **Category**: Waste
- **Plan Step**: Step 2 (Admission limits) & Step 6 (Store hashing exact bytes analyzed)
- **Evidence**:
  `DefinitionIndex.definitions(in: .worktree, git: git)` (`DefinitionIndex.swift:22`) calls:
  ```swift
  let files = await tagged(try await git.blobs(in: snapshot), git: git)
  ```
  Inside `git.blobs(in: .worktree)` (`Jump.swift:124-147`):
  1. `listBlobs(in: .worktree)` runs `ls-files -s -z` and `ls-files -z -m -o --exclude-standard`, and calls `FileManager.default.attributesOfItem` on every modified/untracked path to collect `unhashed`.
  2. `blobs(in:)` immediately calls `try await hashed(listing.unhashed)` -> `hashObjects(paths)` (`git hash-object --stdin-paths`) on **every** regular modified/untracked file in the worktree—including lockfiles, JSON/YAML/Markdown/assets, and multi-megabyte generated or binary files!
  3. Only *after* `git hash-object` has read and SHA-1'd all of those files from disk does `DefinitionIndex.tagged` (`DefinitionIndex.swift:60`) filter `blobs.filter { runtime.hasLanguage(forPath: $0.path) }` and check `largestFile` (1 MB)!
- **Fix**:
  - Filter `unhashed` paths by `runtime.hasLanguage(forPath:)` and `size <= largestFile` *before* hashing, or hash worktree files in-process via `blobID(of: data)` when `read` actually reads them (as `DefinitionIndex.worktreeFiles` at `DefinitionIndex.swift:82` already does, and as Step 6 specifies).

---

### Finding 14 (Waste — Low-Medium Impact): `parseRawPatchZ` copies the entire diff `Data` into `[UInt8]` and allocates a 24-byte `ArraySlice<UInt8>` for every line in the patch
- **Location**: `Sources/SextantCore/Parse.swift:44-215`
- **Category**: Waste
- **Plan Step**: Step 2 (Limits) & Step 5 (Change fast paths)
- **Evidence**:
  - `let bytes = [UInt8](data)` (`Parse.swift:45`) copies the entire `git diff` output `Data` into a new heap `[UInt8]` array (31.3 MB copy in our 1,000-file / 500k-line benchmark, taking **41.02 ms**).
  - `splitPatches` (`Parse.swift:99-133`) materializes `lines: [ArraySlice<UInt8>]` for every line in every patch before `parseFilePatch` runs (for 500,000 lines, `[ArraySlice<UInt8>]` allocates 12 MB of slice structs and checks 4 `starts(with:)` prefixes on every hunk line).
  - `parseFilePatch` (`Parse.swift:165`) evaluates `raw.starts(with: [UInt8(ascii: "@"), UInt8(ascii: "@")])`, allocating a 2-element heap array on every `@`-prefixed line, and decodes every patch header line (`diff --git`, `index`, `---`, `+++`) into a heap `String` (`Parse.swift:176`) even when it doesn't start with `Binary`, `GIT`, `old mode`, `new mode`, or `Submodule`.
- **Fix**:
  - Parse `Data` in place via `data.withUnsafeBytes` (`UnsafeBufferPointer<UInt8>`), streaming lines directly into `parseFilePatch` without copying `Data` to `[UInt8]`, without building intermediate `[ArraySlice<UInt8>]` arrays, and only decoding header lines to `String` after matching byte prefixes (`Binary files `, `GIT binary patch`, `old mode `, `new mode `, `Submodule `).

---

## 4. Correctness Edge Cases That a Performance Rewrite Could Break

When implementing Steps 1–7 of `scratch/perf/plan.md`, the following subtle behaviors in the current git/parsing layer must be preserved (or deliberately fixed with tests):

1. **Quoted paths in non-`-z` output (`Parse.swift:4-34`)**:
   - Even with `-c core.quotePath=false` (`Git.swift:27`), git still C-quotes paths containing `\n`, `\t`, `"`, `\`, or control chars in non-`-z` outputs (`git log --raw`), and octal-escapes all non-ASCII UTF-8 bytes inside any quoted path (`"sp\303\244ce\tname"`). Any command not using `-z` must run `unquoteGitPath`, or switch to `-z` NUL-delimited records.
2. **Rename (`R`) and Copy (`C`) two-path consumption in `-z` raw output (`Parse.swift:58-63`)**:
   - In `git diff --raw -z` and `git log --raw -z`, `R<score>` and `C<score>` entries consume **two** NUL-terminated path fields (`oldPath\0newPath\0`), whereas `A`, `M`, `D`, `T`, `U` consume **one** path field (`path\0`). Miscounting fields desynchronizes the entire `-z` stream.
3. **NUL-separator transition between `--raw` and `-p` in `git diff --raw -p -z` (`Parse.swift:66`)**:
   - Between the last `--raw` path NUL terminator and the first `diff --git` header, git emits an extra NUL byte (`\0`) and/or LF (`\n`). When there are no patches (e.g. only mode-change or empty-file additions without hunks, or all binary/unmerged), the patch section may be empty or have fewer chunks than `changes`.
4. **Hunk header omitted line counts (`Parse.swift:141-147`)**:
   - In unified diffs, a 1-line hunk omits the comma and count: `@@ -5 +7 @@` means `oldStart = 5, oldCount = 1, newStart = 7, newCount = 1`, while `@@ -0,0 +1 @@` means `oldStart = 0, oldCount = 0, newStart = 1, newCount = 1`. `parseHunkHeader` defaults missing count to `1` (`nums.count > 1 ? (Int(nums[1]) ?? 1) : 1`); a fast byte parser must preserve this.
5. **Pure insertions (`oldCount == 0`) in `wholeFile` and `unchangedLinesBefore` (`WholeFile.swift:19, 36-38`)**:
   - For a pure insertion hunk (`oldCount == 0`), git sets `oldStart` to the line **before** the insertion (or `0` when inserting at the very top of the file), whereas for a deletion/modification (`oldCount > 0`), `oldStart` is the **first** affected old line. Both `wholeFile` (`h.oldCount == 0 ? h.oldStart : h.oldStart - 1`) and `unchangedLinesBefore` rely on this exact off-by-one rule.
6. **`\ No newline at end of file` marker (`Parse.swift:188-191, 272-274`)**:
   - Lines in a hunk starting with `\` set `noNewline = true` on the immediately preceding `DiffLine` without incrementing `oldNo` or `newNo`. Note that in a diff where *both* old and new sides lack a trailing newline, `\ No newline at end of file` can appear twice in the same hunk (once after the last `-` line, and once after the last `+` line).
7. **Empty context lines in patches (`Parse.swift:159-164`)**:
   - If a patch contains a completely empty line (0 bytes between `\n` and `\n`) inside an active hunk (`cur != nil`), `parseFilePatch` treats it as a `.context` line with `text: ""` and increments both `oldNo` and `newNo`.
8. **Root commits and empty repositories (`Git.swift:147-154`, `Review.swift:186`)**:
   - When `HEAD` does not exist yet (unborn branch) or a commit has no parent (root commit), `diffArgs` and `scoped` compare against `emptyTreeOid` (`4b825dc642cb6eb9a060e54bf8d69288fbee4904`).
9. **Relative vs absolute `--git-common-dir` in `Git.locate` (`Git.swift:90-97`)**:
   - `git rev-parse --show-toplevel --git-common-dir` returns a relative path (usually `.git`) in the main worktree, and an absolute path in linked worktrees (or when `GIT_COMMON_DIR` is set). `Git.locate` resolves relative `lines[1]` against `path` (NOT `lines[0]`, because `rev-parse --git-common-dir` prints the path relative to its `cwd`, which is `path`).
10. **`ObjectReader.canRead` staleness invariant (`Objects.swift:37-41`)**:
    - `git cat-file --batch` caches loose ref and index state when the long-running process starts. Only immutable 40-hex commit/blob OIDs (`<40-hex>` or `<40-hex>:<path>`) may go through `ObjectReader`; `:path` (index) or `HEAD:path` / `main:path` must not, or they will return stale data after index/ref updates. (Note: if the repository uses SHA-256 object format, OIDs are 64 hex chars, which `rev.count == 40` currently rejects.)
11. **`git grep` exit code `1` when no matches are found (`Explore.swift:91`)**:
    - `git grep` exits with status `1` when zero lines match and `0` when >=1 lines match (and `>=2` on error). `Git.grep` passes `allowedStatuses: [0, 1]`; any replacement runner must keep `1` as a non-error exit status for `grep`.
12. **NUL bytes inside commit subjects in `parseBranches` (`Refs.swift:77`, tested in `ReviewTests.swift:34`)**:
    - `parseBranches` uses `line.split(separator: 0, maxSplits: 4, omittingEmptySubsequences: false)` so that `f[4]` (`subject`) preserves any embedded NUL bytes rather than splitting into a 6th field.
13. **Decoration filtering in `parseDecorations` (`Parse.swift:249-256`)**:
    - `parseDecorations` strips `"HEAD -> "` and `"tag: "` prefixes and drops standalone `"HEAD"` and `"*/HEAD"` pointers so commit badges only show branch and tag names.
14. **Login shell chatter in `pathVariable(inEnvironment:)` (`SearchPath.swift:5-7`)**:
    - Interactive/login shell startup scripts may print arbitrary lines (including earlier `PATH=...` lines) before `/usr/bin/env` runs; taking the `.last { $0.hasPrefix("PATH=") }` after splitting on newlines (`\n` / `\r\n`) is required so the final environment wins.
