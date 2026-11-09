# Scoped Architecture & Efficiency Audit: Syntax Analysis, Names, Definitions & Search Ranking

**Scope:** `Sources/SextantCore/Syntax.swift`, `ContentAnalysis.swift`, `Names.swift`, `DefinitionIndex.swift`, `Jump.swift`; `Sources/SextantApp/JumpActions.swift`, `Peek.swift`; `queries/*/*.scm`, `nix/syntax-runtime.sh`, `flake.nix`, and `$SEXTANT_SYNTAX`.

**Reproducing all benchmark numbers and adversarial checks:**
```sh
nix develop /Users/shrik450/Developer/review-ui -c swift run --package-path /Users/shrik450/Developer/review-ui/scratch/review/argon-sections/analysis -c release AnalysisAuditBench
```

---

## 1. Architecture Audit

### Ownership & Data Flow Today
| Type / File | Current Ownership | Inputs -> Outputs | Architectural Flaws & Duplication |
|---|---|---|---|
| `SyntaxRuntime` / `SyntaxLanguage` (`Syntax.swift`) | Grammar `.dylib` loading (`dlopen`), `Query` compilation (`highlights`, `tags`, `locals`), tree-sitter parsing, token extraction, symbol extraction, line-splitting (`tokensPerLine`). | `[String]` or `String` -> `MutableTree` -> `([Token], [Symbol])` -> `BlobAnalysis`; also `([String], [[Token]])` -> `NameIndex`. | Stateless parser wrapper does 2 separate full parses of the same text (once in `analyze`, once in `names`), converting `[String]` -> `String` -> UTF-16LE `Data` each time. `symbols` extracts both `definition.*` and `reference.*` captures even though no caller in the entire codebase ever uses `reference.*`. |
| `ContentAnalysis` (`ContentAnalysis.swift`) | Actor owning an in-memory LRU (`RecentlyUsed<ContentKey, BlobAnalysis>`) of tokens+definitions, an unbounded dictionary `definitions: [ContentKey: [Definition]]`, and JSON persistence (`definitions.json`). | `([String], oid, SyntaxLanguage, definitions: Bool)` -> `BlobAnalysis`; `[Source]` -> `[ContentKey: [Definition]]`. | Split personality: caches `[Symbol]` inside `BlobAnalysis` (in `recent`) AND `[Definition]` inside `self.definitions`, but does not cache `NameIndex` at all (leaving `FileState` in `Document.swift:264` to own per-instance `SideNames` that are lost whenever a `FileState` is recreated). If `analysis(of: ..., definitions: false)` runs first (from `Peek` or neighbour prep), a later `analysis(of: ..., definitions: true)` discards the cached tokens and re-parses the entire file. Conversely, if `definitions(of:)` already parsed a blob for `DefinitionIndex`, `analysis(of:)` cannot reuse `self.definitions[key]` because `Definition` dropped `Symbol.lines`. |
| `NameIndex` / `LocalCaptures` (`Names.swift`) | Scope tree construction, local definition/reference binding resolution (`resolveNames`), and CSR-style flat arrays (`names`, `lineStarts`, `byBinding`, `bindingStarts`) mapping `(line, column)` <-> `binding` occurrences. | `([String], [[Token]])` -> `Candidate`s via `identifiers(in:tokens:)` + second `parse(text)` + `root.descendant(in:)` per candidate + `localsQuery` -> `NameIndex`. | Built outside `ContentAnalysis` in `Document.swift:289` (`FileState.indexNames`), so it cannot share the `TSTree` from `SyntaxLanguage.analyze` and is never cached by `ContentKey`. Relies on `identifiers(in:tokens:)` (`Reading.swift:19`) + a post-hoc `root.descendant(in:)` tree lookup per identifier rather than walking the already-parsed syntax tree once. |
| `DefinitionIndex` (`DefinitionIndex.swift`, `Jump.swift:117-198`) | Coordinates snapshot blob discovery (`git.blobs(in:)`, `git.listBlobs(in:)`), grammar filtering (`tagged`, `worktreeFiles`), and `git grep` + AST definition intersection (`lookUp`, `places`). | `(Snapshot, Git)` -> `[LocatedDefinition]`; `(word, Snapshot, Git)` -> `(matches: [GrepMatch], definitions: [GrepMatch])`. | Snapshot blob listing (`SnapshotBlob`, `SnapshotListing`, `Git.blobs`, `Git.listBlobs`, `Git.hashed`, `parseTree`, `parseStaged`) lives in `Jump.swift:117-198` instead of `Git`/`DefinitionIndex`. `lookUp` re-lists the entire repository tree via `git ls-tree -r -z` on every lookup in a `.commit` or `.index` snapshot just to find the OIDs of the few files `git grep` matched. |
| `Jump.swift` & `JumpActions.swift` | Query prefix parsing (`parseJumpQuery`), fuzzy scoring (`fuzzyScore`, `rankFuzzy`, `rankJump`), session definition indexing (`indexDefinitions`, `forgetDefinitions`), and `JumpPanel` item creation. | Query `String` + `session.snapshotFiles` + `session.definitions` -> `[JumpItem]`. | `s.definitions` is stored per-`Session` on `@MainActor` (`Panes.swift:23`), filtered on the main thread from `DefinitionIndex`'s flat array, and wiped completely on every refresh (`forgetDefinitions`). `rankJump` copies and re-lowercases all candidates on every keystroke inside an uncancelled `Task.detached`. |
| `Peek` (`Peek.swift`) | Popover `NSViewController` displaying a 40-line window around a definition `GrepMatch`. | `GrepMatch` -> `git.contents` -> `splitLines` -> `blobID` -> `ContentAnalysis.analysis` -> 40-line `NSAttributedString`. | Runs `splitLines(data)` and `blobID(of: data)` on the `@MainActor` over the entire file, has no file-size or binary admission check, and parses the entire file just to colour 40 lines. |

### Unenforced Invariants
1. **UTF-16 vs UTF-8 range invariant:** `Token.range`, `Symbol.range`, `Symbol.nameRange`, `LocalCaptures` ranges, and `NameIndex.Name.range` are all assumed to be UTF-16 code-unit `NSRange`s into LF-joined canonical lines (with trailing `\r` stripped), because `SwiftTreeSitter.Parser` uses `TSInputEncodingUTF16LE` and divides byte offsets by 2. Nothing in the type system enforces this; any mismatch between line splitting, CR stripping, and parser input encoding shifts every range or traps `NSMutableAttributedString`.
2. **`inOutline` sort-order and container-span invariant:** `inOutline(_ definitions: [Symbol])` (`Outline.swift:49-56`, called by `indexedDefinitions` in `Jump.swift:89`) assumes `definitions` is sorted by `range.location`, that `d.range` covers the entire body of any definition that can contain local declarations, and that only `d.kind == "function" || d.kind == "method"` can contain local declarations. All three assumptions are violated by real grammars in `$SEXTANT_SYNTAX` (Swift computed properties, Dart function signatures, Nix bindings).
3. **`LocalCaptures` exact-range match invariant:** `resolveNames` (`Names.swift:74-81`) keys `roles` by `range.location` and requires `found.length == n.range.length`. If a `locals.scm` pattern captures a parent node around the identifier (as upstream `haskell/locals.scm` and `elm/locals.scm` do), `resolveNames` silently drops the role with no diagnostic.
4. **OID-to-bytes identity invariant:** `ContentAnalysis` assumes the `oid` passed to `analysis(of:oid:...)` or `Source(key:...)` is the exact SHA-1 of the bytes parsed. In worktree paths (`Jump.swift:129-158`, `DefinitionIndex.swift:62-68`), `git hash-object` hashes the file in one process and `readWorktreeFile` reads it later in another.

### Fit with the Target Design (Steps 2, 6, 7)
- **Step 2 (Limits & Lifetimes):** Centralize admission limits (`<= 2 MB` blob size, `<= 20,000` UTF-16 units max line length, `!data.prefix(8000).contains(0)`, parser cancellation flag / timeout) at the entry to `ContentAnalysis` and `SyntaxLanguage`, so `Reader`, `Overview`, `Peek`, `DefinitionIndex`, and neighbour prep all go through one gate. Replace `RecentlyUsed`'s `O(N)` linear scan (`ContentAnalysis.swift:228`) with a byte-bounded `O(1)` doubly-linked list / intrusive index LRU.
- **Step 6 (Content):** Unify `SyntaxLanguage.analyze` and `SyntaxLanguage.names` into a single `TSTree` parse inside `ContentAnalysis`, producing demanded outputs (`tokens`, `definitions`, `NameIndex`) in one pass and caching `NameIndex` in `BlobAnalysis` by `ContentKey`. Replace `SwiftTreeSitter`'s allocating `QueryCursor` / `ResolvingQueryMatchSequence` wrapper with direct C `ts_query_cursor_*` execution using precomputed per-capture-ID lookup tables (`[TokenKind?]`, definition kind IDs, local role IDs) and fast byte-slice predicates. Disable `@reference.*` patterns in `tagsQuery` at load time via `ts_query_disable_pattern`.
- **Step 7 (Search & SQLite Definitions):** Persist definitions incrementally in SQLite keyed by `(oid, grammar_version)` with a `(name, oid)` index so `lookUp` and `Go to Anything` don't rewrite a monolithic JSON blob or re-list the entire tree on every lookup. Keep a pre-lowercased contiguous UTF-8 candidate arena with a bounded top-$k$ min-heap (`k = 60`), narrowing across keystrokes and checking `Task.isCancelled` every 4,096 candidates.

---

## 2. Ranked Findings

### Finding 1: `SyntaxLanguage.names` deletes every identifier whose spelling matches its AST `nodeType` (`identifier`, `name`, `variable`, `word`, `symbol`, `var`, `value_name`, `simple_identifier`)
- **Location:** `Sources/SextantCore/Names.swift:296-301`
- **Classification:** Bug (breaks Highlight Uses, Next/Previous Use, and cross-side occurrence matching) + Slowness (`O(candidates × tree_depth)` + 1 heap `String` allocation per candidate)
- **Plan Step:** Step 1 / Step 6
- **Evidence:**
  In `SyntaxLanguage.names(of:tokens:)`:
  ```swift
  candidates.removeAll { c in
      let bytes = UInt32(c.offset * 2)..<UInt32((c.offset + c.range.length) * 2)
      guard let node = root.descendant(in: bytes), node.range.location == c.offset, node.range.length == c.range.length else { return false }
      return !node.isNamed || node.nodeType == c.spelling
  }
  ```
  `root.descendant(in: bytes)` returns the deepest AST node spanning the candidate's range. For every normal identifier, that node is the grammar's identifier leaf node (`identifier`, `simple_identifier`, `variable`, `word`, `symbol`, `var`, `name`, `value_name`, `type_identifier`, `field_identifier`, `property_identifier`, `atom`, etc.), which IS a named node (`node.isNamed == true`) whose `node.nodeType` is the grammar rule name! Whenever a variable, parameter, function, or type in the user's code is named `identifier` (in Rust, Python, TS/JS, Go, C, C++, Zig, Java, Nix, Lua, Ruby), `name` (in GraphQL, PHP, HTML, XML), `variable` (in Haskell), `word` (in Make), `symbol` (in Scheme), `var` (in Erlang), `value_name` (in OCaml), or `simple_identifier` (in Swift/Kotlin), `node.nodeType == c.spelling` evaluates to `true` and **deletes the identifier from `NameIndex`**.
  Running `AnalysisAuditBench` (`[5a]`) confirms **0 occurrences** are indexed in all 14 languages tested:
  ```
  a.rs 'identifier' -> found 0 occurrences in NameIndex (expected >= 1)
  a.py 'identifier' -> found 0 occurrences in NameIndex (expected >= 1)
  a.ts 'identifier' -> found 0 occurrences in NameIndex (expected >= 1)
  a.go 'identifier' -> found 0 occurrences in NameIndex (expected >= 1)
  a.c 'identifier' -> found 0 occurrences in NameIndex (expected >= 1)
  a.zig 'identifier' -> found 0 occurrences in NameIndex (expected >= 1)
  a.hs 'variable' -> found 0 occurrences in NameIndex (expected >= 1)
  Makefile 'word' -> found 0 occurrences in NameIndex (expected >= 1)
  a.scm 'symbol' -> found 0 occurrences in NameIndex (expected >= 1)
  a.erl 'var' -> found 0 occurrences in NameIndex (expected >= 1)
  a.graphql 'name' -> found 0 occurrences in NameIndex (expected >= 1)
  a.php 'name' -> found 0 occurrences in NameIndex (expected >= 1)
  a.ml 'value_name' -> found 0 occurrences in NameIndex (expected >= 1)
  a.swift 'simple_identifier' -> found 0 occurrences in NameIndex (expected >= 1)
  ```
  Additionally, calling `root.descendant(in: bytes)` and `node.nodeType` (`String(cString: ts_node_type(...))`) allocates a heap `String` for every candidate identifier in the file.
- **Fix:** Remove `|| node.nodeType == c.spelling`. To filter out unhighlighted keywords like C++'s `auto` (where the grammar defines a zero-child named keyword node `(auto)`), check whether the leaf symbol is an identifier node (or in Step 6, collect identifier leaves in one `TSTreeCursor` walk by precomputing a `Bool` table over `0..<ts_language_symbol_count(lang)` for symbol names containing `"identifier"`, `"name"`, `"variable"`, `"word"`, `"symbol"`, `"atom"`, `"var"` or having `ts_language_symbol_type(lang, sym) == TSSymbolTypeRegular` with children/supertypes).

---

### Finding 2: `identifiers(in:tokens:)` skips all identifiers inside string interpolations (`"${foo}"`, `` `${foo}` ``, `f"{foo}"`, `"#{foo}"`) and splits non-BMP identifiers at UTF-16 surrogate pairs
- **Location:** `Sources/SextantCore/Reading.swift:3-30`, called by `NameIndex.candidates(in:tokens:)` (`Sources/SextantCore/Names.swift:193`)
- **Classification:** Bug
- **Plan Step:** Step 1 / Step 6
- **Evidence:**
  1. **String interpolations:** In TypeScript, JavaScript, TSX, Python, Ruby, Nix, Bash, Kotlin, Elixir, Dart, and PHP, `highlights.scm` captures the outer `(string)` / `(template_string)` node as `@string` (producing a `.string` token spanning the entire literal), and then emits more specific tokens (`@variable`, `@property`, `@function`, `@embedded`) for the interpolated expressions inside it. Because `identifiers(in:tokens:)` (`Reading.swift:20, 28`) rejects any identifier intersecting ANY `.keyword`, `.comment`, `.string`, or `.number` token (`!skipped.contains(where: { NSIntersectionRange($0, r).length > 0 })`), without checking whether a later token overrides `.string` or whether the AST node is inside an interpolation, every interpolated variable is excluded from `identifiers(in:tokens:)` and `NameIndex`.
     Running `AnalysisAuditBench` (`[5b]`) confirms line 2 is completely missing in all 5 languages:
     ```
     a.ts 'userName' -> occurrences on lines [1] (missing line 2!)
     a.py 'userName' -> occurrences on lines [1] (missing line 2!)
     a.rb 'user_name' -> occurrences on lines [1] (missing line 2!)
     a.nix 'userName' -> occurrences on lines [1] (missing line 2!)
     a.sh 'userName' -> occurrences on lines [1] (missing line 2!)
     ```
  2. **Non-BMP identifiers:** `isIdentifierUnit(_ u: unichar)` (`Reading.swift:3-6`) calls `UnicodeScalar(u)` on each UTF-16 `unichar`. For any non-BMP character (`> U+FFFF`, such as mathematical letters `𝑎`/`𝑥` `U+1D465` or CJK Extension B ideographs), `u` is a UTF-16 surrogate (`0xD800...0xDFFF`), for which `UnicodeScalar(u)` always returns `nil`.
     Running `AnalysisAuditBench` (`[5d]`) on `"let a\u{1D465}b = 1"` returns `["let", "a", "b"]`, splitting the single identifier in two.
- **Fix:**
  - When extracting names from the syntax tree in Step 6, walk the `TSTree` directly to collect identifier nodes (or if using `tokens`, resolve overlapping tokens so the last/innermost token covering an identifier's range determines its `TokenKind`, and in `highlights.scm` map `@embedded` to override `.string`).
  - In `identifiers(in:tokens:)` and `CodeView.identifier(at:)`, decode UTF-16 surrogate pairs (`CFStringGetLongCharacterForSurrogatePair` or `String.UnicodeScalarView`) and use a direct ASCII bitmap + Unicode category check instead of `UnicodeScalar(u)` + `CharacterSet.alphanumerics`.

---

### Finding 3: `SwiftTreeSitter` query execution and redundant `names()` re-parse waste 82–85% of per-file analysis time
- **Location:** `Sources/SextantCore/Syntax.swift:69-140`, `Sources/SextantCore/Names.swift:291-334`, `Sources/SextantApp/Document.swift:230-316`
- **Classification:** Slowness & Waste
- **Plan Step:** Step 6
- **Evidence:**
  In `AnalysisAuditBench` (`1. PHASE BREAKDOWN`), on a 10,000-line (874.6 KB) and 50,000-line (4.55 MB) Swift file:
  ```
  Swift   1000 lines (  83.6 KB): parse=  6.55ms | analyze(tok+sym)=  37.61ms | symbols(parse+sym)= 12.37ms | tokensPerLine= 0.27ms | names(reparse+locals)=  23.94ms | C-cursor-tokens=  3.70ms (6.8x faster than STS tokens)
  Swift  10000 lines ( 874.6 KB): parse= 62.96ms | analyze(tok+sym)= 389.72ms | symbols(parse+sym)=127.80ms | tokensPerLine= 2.27ms | names(reparse+locals)= 245.12ms | C-cursor-tokens= 37.35ms (7.0x faster than STS tokens)
  Swift  50000 lines (4546.4 KB): parse=321.20ms | analyze(tok+sym)=2083.99ms | symbols(parse+sym)=671.66ms | tokensPerLine=11.91ms | names(reparse+locals)=1285.79ms | C-cursor-tokens=188.45ms (7.5x faster than STS tokens)
  ```
  Tracing the exact cost per file when opened in `Reader` (`FileState.analyze` + `FileState.indexNames`):
  1. `SyntaxLanguage.analyze` calls `parse(text)` (63.0 ms at 10k lines), which inside `SwiftTreeSitter.Parser.parse(_:)` (`Parser.swift:109`) allocates a full UTF-16LE `Data` copy (`string.data(using: .utf16LittleEndian)`).
  2. `tokens(in: tree, text)` (`Syntax.swift:111-116`) takes **261.9 ms** at 10k lines (4.2x the parse time!) because:
     - `QueryCursor.next()` constructs a `QueryCapture` for every capture, calling `name?.components(separatedBy: ".")` and `evaluateDirectives` (`Dictionary` allocation per capture).
     - `highlights()` flattens all captures, sorts them all (including `@_name`, `@operator`, `@punctuation`, `@variable` captures that `TokenKind` drops), and wraps each in `NamedRange` (calling `ts_node_start_point`/`ts_node_end_point`).
     - `r.name` calls `nameComponents.joined(separator: ".")` (allocating a `String`), and `TokenKind(capture: r.name)` immediately splits it again with `name.split(separator: ".")` (`Syntax.swift:10`).
     - Replacing this with a C `ts_query_cursor_next_capture` loop and a precomputed `[TokenKind?]` array indexed by `cap.index` takes **37.35 ms** at 10k lines (**7.0x faster**, saving **224.6 ms** per 10k-line file).
  3. `tokensPerLine` (`Syntax.swift:315`) re-sorts `tokens` (`tokens.sorted(by: { $0.range.location < $1.range.location })`) even though `highlights()` already sorted them by `range.lowerBound`.
  4. `FileState.indexNames` (`Document.swift:289-316`) is not cached in `ContentAnalysis` and calls `language.names(of: lines, tokens: ...)` (`Names.swift:291-305`), which joins the lines again, transcodes to UTF-16LE `Data` again, re-parses the entire file a second time, and walks `root.descendant(in:)` for every candidate (**245.1 ms** at 10k lines, **1,285.8 ms** at 50k lines).
- **Fix:** In Step 6, parse once per `(oid, grammar)` in `ContentAnalysis`, execute `highlights`, `tags`, and `locals` directly against the C `TSQueryCursor` API using precomputed capture-ID tables (no `QueryCapture` / `NamedRange` / `String` component splits/joins), and cache `NameIndex` inside `BlobAnalysis`.

---

### Finding 4: `SyntaxLanguage.symbols` executes all `@reference.*` patterns in `tags.scm` (50–80% of tag query time and 80–90% of `Symbol` allocations) and discards 100% of them
- **Location:** `Sources/SextantCore/Syntax.swift:117-140`, `Sources/SextantCore/ContentAnalysis.swift:139, 245`, `Sources/SextantCore/Jump.swift:88`
- **Classification:** Waste & Slowness
- **Plan Step:** Step 6
- **Evidence:**
  Every caller of `SyntaxLanguage.symbols` and `SyntaxLanguage.analyze(text, symbols: true)` in the entire repository (`ContentAnalysis.swift:139` via `indexedDefinitions` in `Jump.swift:88`, and `ContentAnalysis.swift:245`) immediately filters the result with `.filter(\.isDefinition)`. Not a single caller ever uses `isDefinition == false`.
  Yet every `tags.scm` query contains `@reference.call`, `@reference.type`, `@reference.class`, etc., which match every call expression and type reference in the file (and in Ruby's `tags.scm:61`, every identifier in the file), evaluates regex predicates on them (e.g., JS/TS `(#not-match? @name "^(require)$")` on every call), substrings their names, binary-searches `LineIndex` twice per reference, formats `"\($0.isDefinition) \($0.nameRange.location) \($0.nameRange.length)"` into `Set<String>`, and sorts them before discarding them all.
  In `AnalysisAuditBench` (`2. UNUSED @reference.* PATTERNS`), disabling non-`definition.*` patterns at query load time via `ts_query_disable_pattern` speeds up tag query execution by **2.05x to 3.81x** and eliminates 80–90% of `Symbol` allocations:
  ```
  a.rs  : query(with refs)= 46.14ms (syms=25000, defs=5000) | query(def-only)= 22.19ms (syms=5000, defs=5000) | query speedup=2.08x
  a.ts  : query(with refs)= 58.48ms (syms=25000, defs=5000) | query(def-only)= 28.56ms (syms=5000, defs=5000) | query speedup=2.05x
  a.py  : query(with refs)= 46.54ms (syms=25000, defs=5000) | query(def-only)= 22.25ms (syms=5000, defs=5000) | query speedup=2.09x
  a.rb  : query(with refs)=101.69ms (syms=50000, defs=5000) | query(def-only)= 26.68ms (syms=5000, defs=5000) | query speedup=3.81x
  a.go  : query(with refs)= 52.52ms (syms=30000, defs=5000) | query(def-only)= 20.73ms (syms=5000, defs=5000) | query speedup=2.53x
  ```
  Furthermore, `symbols(in:_:)` (`Syntax.swift:118`) builds `LineIndex(text)` by scanning every UTF-16 code unit in the file and binary-searching it 3 times per symbol, even though `ts_node_start_point(node).row` and `ts_node_end_point(node).row` are already stored in every `TSNode` in `O(1)`.
- **Fix:** At `Query` load time in `SyntaxRuntime.load`, call `ts_query_disable_pattern` on every pattern in `tags.scm` that has no `definition.*` capture, remove `isDefinition` from `Symbol`, read line numbers directly from `ts_node_start_point` / `ts_node_end_point`, and deduplicate with a packed integer key instead of `Set<String>` string interpolation.

---

### Finding 5: Broken `locals.scm` handling and queries in Just, Haskell, OCaml, Julia, Scala, and Svelte
- **Location:** `Sources/SextantCore/Names.swift:319-330`, `$SEXTANT_SYNTAX/{just,haskell,ocaml,julia,scala,elm,svelte}/locals.scm`
- **Classification:** Bug (wrong local variable bindings and false cross-method occurrence merging)
- **Plan Step:** Step 1 / Step 6
- **Evidence:**
  Running `AnalysisAuditBench` (`[5c]`) and inspecting `$SEXTANT_SYNTAX/*/locals.scm` reveals 6 distinct bugs:
  1. **`Names.swift:328` drops `@local.reference.*` sub-captures (breaks `justfile`):**
     Line 319 checks `if name == "local.definition" || name.hasPrefix("local.definition.")`, but line 328 checks `else if name == "local.reference"` without `|| name.hasPrefix("local.reference.")`. In `$SEXTANT_SYNTAX/just/locals.scm:27-43`, all reference captures are named `@local.reference.variable` and `@local.reference.function`. Consequently, in a `justfile`, recipe parameters (`build target:`) are bound as isolated locals (`occLines=[1]`) that never match their own uses (`{{target}}` on line 2), while uses of `target` across unrelated recipes are merged together as a global (`occLines=[2, 4]`).
  2. **`scala/locals.scm` merges local variables across all methods of a class:**
     `$SEXTANT_SYNTAX/scala/locals.scm:1-9` marks `(template_body)` (the class body) and `(function_declaration)` (abstract declarations) as `@local.scope`, but does **not** mark `(function_definition)` or `(block)` as `@local.scope`. Every parameter `x` and local `val`/`var` in every method of a Scala class is defined in the enclosing class's `template_body` scope (`local=true->[2, 2, 3, 3]`), merging locals across all methods in the class.
  3. **`haskell/locals.scm` has zero `@local.scope` captures and wrong node ranges:**
     `$SEXTANT_SYNTAX/haskell/locals.scm:1-4` contains no `@local.scope` pattern at all, and puts `@local.definition` on `(signature ...)` and `(function ...)` rather than `(variable)`. `define(_:in:)` in `Names.swift:86` always sees `scope == -1` and exits early, so `resolved.locals` is always `0` on every Haskell file despite `hasLocals == true`.
  4. **`ocaml/locals.scm` misses `let` variable definitions:**
     `$SEXTANT_SYNTAX/ocaml/locals.scm:19` only captures `(value_pattern) @local.definition` (function parameters), missing `(let_binding pattern: (value_name) @local.definition)`. Every `let x = ... in x` binding is treated as a global across the entire OCaml file (`local=false->[2, 3, 5, 6]`).
  5. **`julia/locals.scm` misses all function parameters and scopes function names inside their own body:**
     `$SEXTANT_SYNTAX/julia/locals.scm:1-65` has no pattern for function parameters in `(signature (call_expression (argument_list ...)))`, and captures `(function_definition (signature (call_expression . (identifier) @local.definition.function))) @local.scope` without `(#set! local.definition-scope "parent")`.
  6. **`svelte/locals.scm` and `svelte/tags.scm` are empty comment files (`;; locals`, `;; tags`):**
     Both compile to `Query` objects with `patternCount == 0`, making `hasTags` and `hasLocals` return `true` for `.svelte` files while producing nothing.
- **Fix:**
  - In `Names.swift:328`, check `else if name == "local.reference" || name.hasPrefix("local.reference.")`.
  - In `SyntaxRuntime.load` (`Syntax.swift:290`), treat a `Query` with `patternCount == 0` as `nil`.
  - Add replacement `queries/{scala,haskell,ocaml,julia}/locals.scm` under `queries/`.

---

### Finding 6: Unhandled tree-sitter predicates (`#is-not? local`, `#lua-match?`, `#has-ancestor?`) and missing `capturesAgree` in `tokens(in:_:)` corrupt Ruby, CMake, Haskell, and Julia highlights/tags
- **Location:** `Sources/SextantCore/Syntax.swift:111-120, 158-165`, `$SEXTANT_SYNTAX/{ruby,cmake,haskell,julia,javascript,typescript,tsx,nix}/`
- **Classification:** Bug (wrong syntax highlighting and bogus tag matches)
- **Plan Step:** Step 1 / Step 6
- **Evidence:**
  Beyond the known Zig `#lua-match?` issue in `plan.md`:
  1. **`#is-not? local` is always `true` in `SwiftTreeSitter`, turning every Ruby identifier into `.function`:**
     In `SwiftTreeSitter/Predicate.swift:99, 147`, `.init(string: text)` sets `groupMembershipProvider: { _, _, _ in false }`, so `.isNot("local")` is always `true`.
     In `$SEXTANT_SYNTAX/ruby/highlights.scm:1-4`:
     ```scm
     (identifier) @variable
     ((identifier) @function.method
      (#is-not? local))
     ```
     Because `(#is-not? local)` always succeeds, **every identifier in every Ruby file** (parameters, local variables, assignments) is highlighted as `@function.method` (`.function`), and in `$SEXTANT_SYNTAX/ruby/tags.scm:60-64` every identifier matches `@reference.call`. (Verified in `AnalysisAuditBench`: `local_var = alpha + beta` emits `.function` tokens for `local_var`, `alpha`, and `beta`.)
     `(#is-not? local)` also appears in `{javascript,typescript,tsx,nix}/highlights.scm`, causing local variables named `module`, `console`, `window`, `document`, `arguments`, `require`, `map`, `toString`, `import`, etc. to be highlighted as builtins even when shadowed locally.
  2. **`#lua-match?` in `cmake/highlights.scm:6, 221`:**
     Line 6 (`(#lua-match? @constant "^[%u@][%u%d_]+$")`) always succeeds, highlighting every `unquoted_argument` in every CMake command as `@constant`. Line 221 (`(#lua-match? @keyword.directive "^#!/")`) always succeeds, highlighting the first `# comment` of every `CMakeLists.txt` as `@keyword.directive` (`.keyword`) instead of `.comment`.
  3. **Two-capture `#eq?` is ignored in `SyntaxLanguage.tokens(in:_:)` (`Syntax.swift:113`):**
     `SyntaxLanguage.capturesAgree(in: match, ns)` is only called in `symbols(in:_:)` (`Syntax.swift:119`), not in `tokens(in:_:)` (`Syntax.swift:113`). `$SEXTANT_SYNTAX/haskell/highlights.scm` has 3 two-capture `#eq?` predicates (lines 159, 179, 370: `(#eq? @_name @variable)` and `(#eq? @_name @function)`), which `SwiftTreeSitter` evaluates as `.eq([], captureNames: ...)` -> vacuously `true`.
  4. **`#has-ancestor?` in `julia/highlights.scm:326`:**
     `(#has-ancestor? @variable.builtin index_expression)` is parsed as `.generic` (always `true`).
- **Fix:** In Step 6's C-API predicate evaluator:
  - Evaluate two-capture `#eq?` and `#not-eq?` for all queries (`highlights`, `tags`, `locals`), not just `tags`.
  - Support `#lua-match?` (translating Lua character classes `%u` -> `A-Z`, `%d` -> `0-9`, `%a` -> `A-Za-z`, `%w` -> `A-Za-z0-9`, `%s` -> whitespace) and `#has-ancestor?` (walking `ts_node_parent`).
  - For `#is-not? local` in Ruby (`ruby/highlights.scm:3-4` and `ruby/tags.scm:60-64`), either evaluate against `LocalCaptures` or strip the bogus bare `(identifier) @function.method (#is-not? local)` rule in `nix/syntax-runtime.sh` / `queries/ruby/`.

---

### Finding 7: Missing and broken definition rules in Swift, TypeScript/TSX, Go, Dart, and Zig `tags.scm` + `inOutline` leaks local variables inside Swift computed properties
- **Location:** `Sources/SextantCore/Outline.swift:49-56`, `Sources/SextantCore/Jump.swift:87-92`, `$SEXTANT_SYNTAX/{swift,typescript,tsx,go,dart,zig}/tags.scm`
- **Classification:** Bug (missing definitions in Outline / Go to Anything / Peek / Jump to Definition, and local variables polluting Outline & Go to Anything)
- **Plan Step:** Step 1 / Step 6
- **Evidence:**
  Verified in `AnalysisAuditBench`:
  1. **Swift (`$SEXTANT_SYNTAX/swift/tags.scm` + `Outline.swift:49-56`):**
     - `inOutline` (`Outline.swift:53`) only updates `functionEnd = NSMaxRange(d.range)` when `d.kind == "function" || d.kind == "method"`. In `tree-sitter-swift`, every local `let`/`var` inside a function or computed property is a `(property_declaration)` captured as `@definition.property`. Because a computed property (`var label: String { let localInComputed = "k"; return localInComputed }`) has `d.kind == "property"`, `functionEnd` is not updated, so `localInComputed` gets `inOutline = true` and pollutes both the file Outline and Go to Anything (`["class:TokenKind@3", "property:label@5", "property:localInComputed@6", ...]`).
     - `swift/tags.scm` only matches methods/initializers/properties inside `(class_body)`, not `(enum_class_body)`. Inside any Swift `enum`, `init` and computed `var` properties are completely missed, and `func` falls through to top-level `function` instead of `method`.
     - `swift/tags.scm` has no pattern for `typealias_declaration`, `enum_entry` (`case`), or `extension` (`class_declaration` where `name:` is `(user_type (type_identifier))` rather than `(type_identifier)`), and captures `subscript_declaration`'s first parameter name instead of `"subscript"`.
  2. **TypeScript & TSX (`$SEXTANT_SYNTAX/{typescript,tsx}/tags.scm`):**
     Has no pattern for `type_alias_declaration` (`type Foo = ...`), `enum_declaration` (`enum Status { ... }`), or exported non-function constants (`export const MAX = 100`).
  3. **Go (`$SEXTANT_SYNTAX/go/tags.scm:29-39`):**
     Lines 29–39 of upstream `go/tags.scm` have `@name` captures without any `@definition.*` capture on `package_clause`, `var_declaration`, and `const_declaration`, so Go `const` and `var` definitions are never indexed.
  4. **Dart (`$SEXTANT_SYNTAX/dart/tags.scm:6-36`):**
     Captures `(method_signature)` and `(function_signature)` as `@definition.method` / `@definition.function` without the sibling `(function_body)`. Every Dart function/method's `Symbol.lines` span covers only its 1-line signature, so changes inside a Dart function body never mark the function as `.modified` in `Outline` or `changedDefinitions`, and `inOutline` never suppresses declarations inside Dart function bodies.
  5. **Zig (`queries/zig/tags.scm:48-96`):**
     Uses `(_) @_value (#not-match? @_value "^((extern|packed)\\s+)?(struct|union|enum|opaque)\\b|^error\\s*\\{")` on 5 `@definition.constant` patterns. Because `(_) @_value` captures the entire RHS AST subtree of every `const` declaration (which in Zig includes every `const Foo = struct { ... }` file/type container), `SwiftTreeSitter`'s `cachingContext` extracts a full `String` copy of the entire struct body for every `const` declaration.
- **Fix:**
  - Add `queries/{swift,typescript,tsx,go,dart}/tags.scm` fixing the missing node types and spans, and in `queries/zig/tags.scm` remove the `(_) @_value (#not-match? @_value ...)` regex (since `@definition.struct`/`enum`/`union` already precede `@definition.constant` and win deduplication, or check the child's node type directly).
  - In `inOutline` (`Outline.swift:53`), also advance the container barrier for `d.kind == "property"` (or exclude `property_declaration` nodes inside `statements` / `computed_getter` / `computed_setter` in `queries/swift/tags.scm`).

---

### Finding 8: `DefinitionIndex.lookUp` always fails on `$`-prefixed identifiers (`$foo`), hyphenated names (`make-point`), and `!`/`?` names (`swap!`), runs full-repo `git ls-tree -r` on every commit lookup, and retains all matched worktree file `Data` buffers at once
- **Location:** `Sources/SextantCore/DefinitionIndex.swift:35-94, 109-118`, `Sources/SextantCore/Jump.swift:129-158`, `Sources/SextantCore/Explore.swift:81-99`
- **Classification:** Bug + Slowness + Unbounded Memory
- **Plan Step:** Step 1 / Step 2 / Step 7
- **Evidence:**
  1. **`$foo` fails `git grep -w` (`DefinitionIndex.swift:36`, `Explore.swift:81`):**
     `Reading.swift:5` and `CodeView.swift:925` include `"$"` in `isIdentifierUnit`, so `wordAtCaret` extracts `"$foo"` in JS/TS/PHP/Bash/Make/Nix. `DefinitionIndex.lookUp` calls `git.grep(name, ..., word: true)` which passes `-F -w -e "$foo"`. Because `$` is not a POSIX word character (`[A-Za-z0-9_]`), `git grep -w` requires a word character immediately before `$` and returns **0 matches** whenever `$foo` is preceded by whitespace, `(`, `=`, or start of line.
  2. **Hyphenated / `!` / `?` identifiers fail `d.name == name` (`DefinitionIndex.swift:112`):**
     In Clojure, Scheme, CSS, Nix, Make, Just, Bash, and Fish, `tags.scm` indexes definitions with `-`, `!`, or `?` in `d.name` (e.g., `make-point`, `swap!`, `--accent`), but `CodeView.identifier(at:)` stops at `-`, `!`, `?` (producing `"make"` or `"swap"`). `places(of:in:matches:)` filters by `f.definitions.filter { $0.name == name }`, which never matches (`"make-point" != "make"`), so Peek Definition and Jump to Definition always fail on those symbols.
  3. **Full-repo `git ls-tree -r -z` on every lookup (`DefinitionIndex.swift:37, 40-41`):**
     For any `.commit` or `.index` snapshot, `lookUp` unconditionally runs `async let listed = git.listBlobs(in: snapshot)` (`git ls-tree -r -z <commit>` or `git ls-files -s -z`) across the **entire repository**, parsing 100k+ paths into `SnapshotBlob` structs just to filter down to the 1–5 paths returned by `git grep`.
  4. **Unbounded task group & simultaneous `Data` retention in `worktreeFiles` (`DefinitionIndex.swift:77-94`):**
     When `lookUp` runs on `.worktree` for a common name matching $M$ files, `worktreeFiles` spawns $M$ concurrent tasks with no concurrency cap, eagerly reads every file (`up to 1 MB` each) from disk and computes `blobID(of: data)` **even for files already cached in `ContentAnalysis.definitions`**, and captures `{ data }` in `ContentAnalysis.Source.read` (`DefinitionIndex.swift:88`), holding all $M$ file `Data` buffers in memory simultaneously until `analysis.definitions(of:)` completes.
  5. **`git.blobs(in: .worktree)` hashes non-code and oversized worktree files before `tagged` filters them (`DefinitionIndex.swift:24`, `Jump.swift:129-158`):**
     `definitions(in: .worktree)` calls `git.blobs(in: .worktree)`, which passes **every** modified and untracked regular file in the worktree (including multi-hundred-MB data/binary/log files and extensions with no grammar) to `git hash-object --stdin-paths` before `tagged()` filters by `runtime.hasLanguage(forPath:)`, `language.hasTags`, and `largestFile`.
- **Fix:**
  - In Step 7, once definitions are indexed in SQLite with a `name -> (oid, line, kind)` index, `Peek Definition` and `Jump to Definition` should query the definition index directly instead of running `git grep` first (falling back to `git grep` only for Find References or when no definition is found).
  - When `git.grep` is called with `word: true` on a needle whose first or last character is non-word (like `$foo`), omit `-w` or match word boundaries only on the alphanumeric ends.
  - In `worktreeFiles`, do not capture `data` in `read: { data }` across all files at once; filter `unhashed` paths by `runtime.language(forPath:)?.hasTags == true` and `size <= largestFile` *before* hashing, and hash the exact `Data` read during `read()` via `blobID(of:)` inside bounded workers.
  - In `lookUp` on `.commit` / `.index`, pass `-- <paths>` to `git ls-tree` (or read `<commit>:<path>` directly) for only the matched paths instead of listing the entire repository tree.

---

### Finding 9: `rankJump` and `fuzzyScore` take up to 4.27 seconds per keystroke at 1.5M candidates, spawn uncancelled `Task.detached` tasks on every keystroke, have a greedy prefix bug, and show `"Nothing matches"` for `#`
- **Location:** `Sources/SextantCore/Jump.swift:13-45, 242-255`, `Sources/SextantApp/JumpActions.swift:27-98`
- **Classification:** Slowness + Waste + Bug
- **Plan Step:** Step 1 / Step 7
- **Evidence:**
  1. **Per-keystroke scaling (`AnalysisAuditBench` `3. SEARCH RANKING`):**
     ```
     Candidates=    10000: prefix('p')=   2.50ms | fuzzy('pai')=  14.16ms | long('performActionItem_42')=  27.05ms
     Candidates=   100000: prefix('p')=  25.16ms | fuzzy('pai')= 150.63ms | long('performActionItem_42')= 282.14ms
     Candidates=   500000: prefix('p')= 130.07ms | fuzzy('pai')= 765.85ms | long('performActionItem_42')=1445.24ms
     Candidates=  1500000: prefix('p')= 414.20ms | fuzzy('pai')=2276.89ms | long('performActionItem_42')=4267.51ms
     ```
     Why a longer query (`performActionItem_42`, **4.27 s**) is **10.3x slower** than a 1-char query (`p`, **414 ms**):
     - For every candidate that does not contain the query as an exact substring (>99.9% of candidates for a longer query), `fuzzyScore` (`Jump.swift:21-34`) allocates `let wanted = Array(q)` (`[Character]` heap allocation per candidate), iterates over `candidate` by extended grapheme clusters (`for c in candidate`), and calls `Character(c.lowercased())` on **every character of every candidate** (~30M `String` + `Character` allocations per keystroke at 1.5M candidates).
     - For every definition (`Jump.swift:249`), `rankJump` passes `candidate: d.name, name: d.name`. When `n.contains(q)` is `false` on line 18, line 19 (`else if candidate.lowercased().contains(q)`) lowercases `d.name` and searches it a **second time** on all 1.2M definitions even though `candidate == name`.
     - For every file (`Jump.swift:245`), `(p as NSString).lastPathComponent` bridges `p` and allocates a new `String` on every keystroke.
     - `rankJump` appends all matching `(Int, JumpMatch)` pairs into `scored` and sorts the entire array (`scored.sort { $0.0 > $1.0 }`) instead of maintaining a bounded top-60 min-heap.
  2. **Uncancelled `Task.detached` pile-up (`JumpActions.swift:68-70`):**
     `JumpPanel.search()` (`JumpPanel.swift:122`) cancels `searching`, which calls `jumpItems(for: text)`. Inside `jumpItems`, line 68 awaits `Task.detached(priority: .userInitiated) { rankJump(...) }.value`. Cancelling `searching` does **not** propagate cancellation to `Task.detached`, and `rankJump` never checks `Task.isCancelled`. Typing 5 characters rapidly runs 5 full 1.5M-candidate scans concurrently across 5 CPU cores.
  3. **Greedy character consumption bug in `fuzzyScore` (`Jump.swift:24-31`):**
     The fuzzy loop greedily matches `wanted[qi]` against the first matching character in `candidate`, even when it is a lowercase interior character (`+1`) and a word-start character (`+10`) appears later. In `AnalysisAuditBench`:
     `fuzzyScore("rwc", candidate: "Sources/SextantApp/RepoWindowController.swift", name: "RepoWindowController.swift")` matches `'r'` against `'r'` inside `"Sou[r]ces"` (`+1`) instead of `"[R]epo"` (`+10`), giving base score `20` instead of `30`.
  4. **Typing `#` alone in Go to Anything displays `"Nothing matches"` (`JumpActions.swift:63-75`):**
     `parseJumpQuery("#")` returns `.definitions("")`. In `jumpItems(for: "#")`, `.definitions("")` falls into `rankJump("", ...)` -> `fuzzyScore("", ...)` returns `nil` -> returns `[]`, and `JumpPanel.show` displays `"Nothing matches"` because `!field.stringValue.isEmpty`. When `q.isEmpty` in `.definitions`, it should return `defs.prefix(limit)` ( prioritizing changed files) just as `.fileDefinitions("")` and `.commands("")` do.
  5. **Transient indexing failure permanently disables Go to Anything definitions for the session (`JumpActions.swift:31-42`), and `< 50` files never show progress (`ContentAnalysis.swift:109`):**
     In `indexDefinitions`, if `index.definitions(in:git:)` throws, `found` is `nil`, and line 39 sets `s.definitions = found?.filter(\.inOutline) ?? []` (non-nil `[]`). Because line 28 guards `s.definitions == nil`, `indexDefinitions` never retries. And in `ContentAnalysis.swift:109`, `if done % 50 == 0 || done == missing.count` never reports initial `(0, missing.count)` progress, so batches of `< 50` unindexed files show no progress text while parsing.
- **Fix:**
  - In Step 1: handle `.definitions("")` in `jumpItems(for:)`, leave `s.definitions = nil` when `found == nil`, report `progress(0, missing.count)` at the start of `ContentAnalysis.definitions(of:)`, and replace `Task.detached` in `jumpItems` with a structured task or `withTaskCancellationHandler` + periodic `Task.isCancelled` checks in `rankJump`.
  - In Step 7: precompute a flat candidate arena (storing UTF-8 bytes, pre-lowercased UTF-8 bytes, filename start offset, and word-boundary bitmask), match on `name` before falling back to full `candidate` path, and maintain a fixed-size 60-element min-heap.

---

### Finding 10: `ContentAnalysis.prune` wipes the entire repository definition cache when `current` is empty, `RecentlyUsed` has `O(N)` eviction stalls on the actor, and `SyntaxRuntime.load` reads & SHA-256 hashes 49.8 MB of `.dylib` binaries
- **Location:** `Sources/SextantCore/ContentAnalysis.swift:56-70, 91-128, 220-233`, `Sources/SextantCore/Syntax.swift:262-298`
- **Classification:** Bug + Slowness + Waste
- **Plan Step:** Step 1 / Step 2 / Step 6 / Step 7
- **Evidence:**
  1. **`ContentAnalysis.prune(keeping:)` wipes the cache (`ContentAnalysis.swift:123-128`, called by `DefinitionIndex.swift:26`):**
     ```swift
     public func prune(keeping current: Set<ContentKey>) {
         guard definitions.count > current.count * 3 else { return }
         definitions = definitions.filter { current.contains($0.key) }
         unsaved = true
         saveSoon()
     }
     ```
     If `current` is empty (e.g., viewing a commit/branch with no tagged files) or has $< \frac{1}{3}$ the blobs of another branch/worktree sharing `commonDir/sextant/definitions.json`, `definitions.count > current.count * 3` triggers and **deletes every cached definition for every other branch, commit, and worktree**, overwriting `definitions.json` with `{}` (verified in `AnalysisAuditBench` `[5e]`: `0/5 cached blobs remaining`).
  2. **`RecentlyUsed.insert` is `O(entries.count)` per eviction inside the `ContentAnalysis` actor (`ContentAnalysis.swift:228`):**
     `while cost > budget, let oldest = entries.min(by: { $0.value.used < $1.value.used })` scans the entire dictionary on every evicted entry. In `AnalysisAuditBench` (`4. RecentlyUsed`), 10,000 evictions at 50,000 entries take **28,325.9 ms (2.83 ms per eviction)** directly on the `ContentAnalysis` actor executor, blocking all concurrent callers.
  3. **`ContentAnalysis` cache-miss between `definitions: false` and `definitions: true` (`ContentAnalysis.swift:59`):**
     When `Peek` (`Peek.swift:112`) or `prepareNeighbors` calls `analysis(of: ..., definitions: false)`, `recent` stores `BlobAnalysis(tokens: ..., definitions: nil)`. When the user then opens that file (`definitions: true`), line 59 misses `recent` and re-parses and re-highlights the entire file from scratch instead of reusing `hit.tokens` or `self.definitions[key]`.
  4. **`ContentAnalysis.definitions(of:)` drops partial progress on cancellation and does redundant `splitLines(data).joined(separator: "\n")` (`ContentAnalysis.swift:97-113, 139`):**
     If `s.indexTask` is cancelled after parsing 5,000 of 6,000 files, `for try await` throws `CancellationError` and skips `saveSoon()` on line 113. And line 139 decodes `data`, splits it into `N` heap-allocated line `String`s (`splitLines(data)`), and immediately rejoins them (`joined(separator: "\n")`) just to pass a single `String` to `symbols(_:)`.
  5. **`SyntaxRuntime.load` reads and SHA-256 hashes 49.83 MB of parser `.dylib`s at runtime (`Syntax.swift:289`):**
     `_ = read("parser")` reads each grammar's compiled binary into a `Data` buffer and hashes it with SHA-256 (`49.83 MB` across the 49 grammars, `19.3–34.1 ms` of pure I/O + hashing), even though `nix/syntax-runtime.sh` builds an immutable `$out` directory and can precompute `version` into `languages.json` at Nix build time.
  6. **`SyntaxRuntime.entry(forPath:)` misses multi-dot fileTypes like `erlang`'s `"app.src"` (`Syntax.swift:262-266`):**
     `languages.json` lists `"app.src"` under `erlang`, but `entry(forPath: "foo.app.src")` only checks `file` (`"foo.app.src"`) and `ext` (`"src"`), so `.app.src` files never match Erlang.
- **Fix:**
  - In Step 2: replace `RecentlyUsed` with an `O(1)` doubly-linked list LRU bounded by estimated bytes.
  - In Step 6: compute grammar `version` at build time in `nix/syntax-runtime.sh` (`languages.json`), stop calling `splitLines(data).joined(separator: "\n")` in `definitions(of:)`, and unify `BlobAnalysis` with `self.definitions`.
  - In Step 7: replace `definitions.json` and `prune(keeping:)` with incremental SQLite storage (`defer { if done > 0 { saveSoon() } }` on cancellation).

---

### Finding 11: `Peek` runs `splitLines` and SHA-1 `blobID` on `@MainActor`, has no file-size or binary admission guard, parses the whole file for 40 lines, and can crash or leak popovers on stale anchors
- **Location:** `Sources/SextantApp/Peek.swift:87-125`, `Sources/SextantApp/WindowActions.swift:533-550`
- **Classification:** Bug + Main-Thread Slowness + Waste
- **Plan Step:** Step 1 / Step 2 / Step 3
- **Evidence:**
  1. **Main-thread work & missing admission limits (`Peek.swift:96-105`):**
     `Peek` is `@MainActor`. In `show(_ i: Int)`, `Task { ... }` inherits `@MainActor`:
     - `await git.contents(of: d.path, in: snapshot)` calls `readWorktreeFile(path)` synchronously on `@MainActor` when `snapshot == .worktree` (up to 4 MB; and for `.commit`/`.index`, `cat-file` has no size cap at all).
     - `let all = splitLines(data)` and `blobID(of: data)` run synchronously on the **main thread** over the entire file.
     - `await Peek.tokens(all, ...)` parses and highlights the **entire file** with no size or line-length admission check (unlike `DefinitionIndex.largestFile = 1 << 20`), only to slice 40 lines (`shown = start..<min(all.count, start + 40)`).
  2. **Uncancelled tasks on `Tab` cycling (`Peek.swift:87-106`):**
     Pressing `Tab` / `Shift-Tab` calls `show(index ± 1)`, which spawns a new `Task` without cancelling the previous `Task` and leaves the previous definition's code displayed under the new definition's `path:line` header while loading.
  3. **Stale `caretAnchor` crash / detached popover (`WindowActions.swift:534-549`):**
     `peekDefinition` captures `let anchor = reader.caretAnchor` *before* `await lookUp(word, in: t)`. If the user scrolls, switches files, or closes the pane while `lookUp` is running, `anchor.1` (`CodeView`) may have scrolled or been removed from its window (`anchor.1.window == nil`), causing `NSPopover.show(relativeTo:of:preferredEdge:)` to either point at the wrong location or throw an uncaught Objective-C `NSInvalidArgumentException`.
- **Fix:**
  - Re-read `reader.caretAnchor` and verify `reader.wordAtCaret == word` and `anchor.1.window != nil` *after* `await lookUp(word, in: t)` returns.
  - Store the loading `Task` on `Peek` and cancel it in `show(_:)` and `viewWillDisappear()`.
  - Move `git.contents`, size/binary/line-length admission checks, `splitLines`, and `blobID` off `@MainActor`. If the file exceeds syntax admission limits, render the 40-line slice as plain text without parsing.

---

## 3. Correctness Edge Cases That a Performance Rewrite Could Break

When implementing Steps 2, 6, and 7 of the plan, preserve these exact invariants (covered by `SyntaxTests`, `TagsTests`, `NamesTests`, `DefinitionIndexTests`, and `JumpTests`):

1. **UTF-8 Parser Byte Offsets vs UTF-16 `NSRange`s (`Syntax.swift`, `Names.swift`, `CodeView`, `Peek`):**
   AppKit's `NSString`, `NSMutableAttributedString`, and `NSTextView` index strictly by UTF-16 code units. If Step 6 switches Tree-sitter from `TSInputEncodingUTF16LE` to `TSInputEncodingUTF8` (to eliminate the 2x UTF-16 `Data` copy), `ts_node_start_byte` / `ts_node_end_byte` and `ts_node_start_point.column` will be UTF-8 byte offsets. Every line containing multi-byte UTF-8 (e.g., `—`, `…`, `‘`, emoji `🚀`) must convert UTF-8 byte columns to UTF-16 code-unit offsets (fast path: when a line's `utf8.count == utf16.count`, UTF-8 column == UTF-16 column in `O(1)`).
2. **Token Specificity & Multi-Line Split Ordering (`Syntax.swift:74, 113, 305-331`):**
   `CodeView` and `Peek` apply tokens in array order so later tokens overwrite earlier ones. At the same start offset, a capture with more dot-components (`@variable.builtin`, 2) or a later `patternIndex` in `highlights.scm` must come *after* a broader capture (`@variable`, 1, or earlier `patternIndex`). When `tokensPerLine` splits a multi-line token (like a block comment or multi-line string starting on line 0) across line $L$, its slice on line $L$ starts at column 0 of line $L$; any single-line token inside it at column 0 of line $L$ must remain *after* the multi-line token slice on line $L$.
3. **First-Pattern-Wins Symbol Deduplication vs Start-Offset Sorting (`Syntax.swift:79-82, 136-138`):**
   In `SyntaxLanguage.symbols`, when multiple patterns in `tags.scm` match the same `@name` range (e.g. Swift's `@definition.method` on `class_declaration` vs `@definition.function` on `function_declaration`), the *first pattern emitted by the query* must win deduplication by `nameRange`, and the deduplicated symbols must *then* be sorted by `declaration(around:within:).range.location` before `inOutline` (`Outline.swift:49`) runs. Reversing deduplication and sorting breaks `SyntaxTests.membersSpanTheirOwnLinesNotTheTypeAroundThem`.
4. **Two-Capture `#eq?` / `#not-eq?` Predicates (`Syntax.swift:158-165`):**
   `queries/haskell/tags.scm:56` and `queries/erlang/tags.scm:26` rely on `(#not-eq? @_previous @name)` to suppress duplicate definitions across multi-clause functions (`area (Circle r) = ...; area (Rect w) = ...`). Step 6's C-API predicate evaluator must support capture-vs-capture `#eq?` and `#not-eq?` or `TagsTests` for Haskell and Erlang will fail.
5. **`LocalCaptures` Scope & Placement Semantics (`Names.swift:54-146, 310-334`):**
   - Root node exclusion (`c.node.parent != nil` in `Names.swift:317`): the root AST node must never be recorded as a `@local.scope`, so top-level identifiers receive non-local bindings (`id >= localCount`) and can match across diff sides by spelling (`Document.swift:350`).
   - Duplicate scope ranges (`Names.swift:56-60`): when two `@local.scope` captures have the exact same `range`, `inherits` must be `last.inherits && s.inherits` (so Ruby's `(#set! local.scope-inherits false)` is not overwritten by a second pattern on the same node).
   - Forward references within a scope (`NamesTests.swift:40`) and two-pass `.nearest` resolution (`Names.swift:120-123` for Ruby block assignments, `NamesTests.swift:62`) require all `.innermost` and `.parent` definitions in all scopes to be registered before `.nearest` definitions and `.reference` lookups run.
6. **Trailing `\r` Canonicalization (`ContentAnalysis.swift:242`, `Names.swift:292`):**
   Both token/symbol analysis and name indexing must strip trailing `\r` per line before computing offsets (`DefinitionIndexTests.swift:92`).
