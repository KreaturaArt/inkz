# Data-oriented design: inkz, fino and zirp compared

This document lists the architectural choices of inkz and of the two reference projects its
migration plan drew on (`docs/DODMigrationPlan.md` §2, techniques T1–T19), and focuses on where
they differ. For each difference it says why each project chose as it did and what that choice
costs it.

| Project | Snapshot | What it is |
|---|---|---|
| **inkz** | `main` @ `9018c6d` (2026-11-20) | An ink runtime and compiler for embedding in games. It must match C# ink v1.2.1's behaviour exactly. |
| **fino** | `reference/fino` @ `67acdb3` (2026-08-01) | A toy, dynamically typed language. It explores DOD in every compiler stage (four AST layouts) and mutable value semantics in the VM. |
| **zirp** | `reference/zirp` @ `cf29122` (2026-10-18) | A resilient Zig parser in the rust-analyzer style ("Resilient LL Parsing"). It reworks `std.zig`'s tokenizer, parser and Ast, and measures itself against upstream. |

C# ink (`reference/ink`) is the semantic ground truth for inkz (D13). It is mentioned only
where it explains an inkz choice.

**Status caveats for the references:**
- **fino:** only `post_tree` is live. `forest_pointer`, `index_sea` and `moar_smaller` are stale
  benchmark experiments behind `@compileError` (`src/root.zig:5-10`). Their numbers in
  `benchmarks.txt` come from the first commit.
- **zirp:** only the Tokenizer, Parser, grammar, Ast and AstRlAnnotate are its own. `AstGen.zig`
  and `Render.zig` are upstream copies that nothing compiles, so zirp has no IR or backend of
  its own.

**How this was gathered.** All three trees were read in full; struct sizes were measured in
scratch builds; zirp's `--compare-std` table was run. Citations are `file:line` relative to
each project's root.

---

## 0. What each project optimises for

Almost every difference below follows from this table.

| | inkz | fino | zirp |
|---|---|---|---|
| Primary goal | Fixed, predictable memory and exact ink semantics when embedded in a host game | The smallest AST and the fastest parse+compile; affordable value semantics | Parse any input, broken or not, into a tree that tools can use; beat upstream on memory |
| Workload | Compile once (offline or at load), then play many short `cont()` calls | Parse and compile a 1M-line file; REPL | Parse whole files repeatedly (editor, formatter, analysis) |
| Input language | ink: context-sensitive, whitespace-significant, backtracking grammar | A small LL(1)-ish language with significant newlines | Zig: a context-free LL grammar designed to be easy to parse |
| Behaviour target | Bit-compatible with C# ink: output, RNG, saves, float strings | Its own semantics | Upstream `std.zig.Ast` coverage (it parses all of std) |
| Engineering rules | TigerStyle: no recursion, no allocation after init, bounded everything, assertion density, lint | None formal | matklad/TigerBeetle flavour (`maybe()`), no formal lint |
| Shipping mode | ReleaseSafe (D11) | ReleaseFast (benchmarks) | ReleaseFast (benchmarks) |

---

## 1. Source text

| Choice | inkz | fino | zirp |
|---|---|---|---|
| Buffer | All files of a compilation concatenated into one `Space`; INCLUDEs found depth-first with an explicit stack (`compiler/source_space.zig:1-9`) | One file, owned by `main`, `[:0]const u8` (`main.zig:91-95`) | One file, borrowed `[]const u8` (`Tokenizer.zig:7`; `Ast.zig:9`) |
| Sentinel | None; scanning rules check bounds | NUL sentinel, load-bearing: the lexer never bounds-checks (`Lexer.zig:107-121`) | **Removed** relative to upstream: `byte()` returns 0 at `text.len` (`Tokenizer.zig:91-94`) |
| Preprocessing | Comments stripped into a second buffer first; block comments keep their newlines (`lexical.zig:11-35`) | None | None; comments become `.comment` tokens, then are dropped (`Parser.zig:187`) |
| Offset width | `u32`, asserted; 16 MiB cap (`limits.zig:281`) | `u32` | `u32` (`Ast.ByteOffset`) |
| Line/column | Computed lazily: linear scan of the file table, then count `\n` (`source_space.zig:76-87`, `lexical.zig:82-89`) | None | None (byte offsets only) |

**Differences, why, and tradeoffs**

- **Multi-file space (inkz only).**
  - *Why:* ink has `INCLUDE`. One concatenated space makes token and node indices global, so the
    whole compilation is one parse and one set of arrays.
  - *Cost:* a file table and a linear `location` lookup. fino and zirp parse one file each and
    need neither.
- **Comment stripping by copy (inkz only).**
  - *Why:* this is what ink's own parser does (`CommentEliminator`). Running the rules on
    comment-free text keeps the port faithful and spares every rule from skipping comments.
  - *Cost:* an extra buffer the size of the source, and every offset points into the stripped
    text. Columns after a mid-line `/*…*/` are off, and nothing maps back to the original
    bytes. zirp goes the other way and tokenises comments, because a formatter must keep them.
    fino just skips `#` comments inside the lexer.
- **Sentinel.**
  - *fino* keeps upstream Zig's trick: the NUL ends the input, so there are no bounds checks
    and the lexer is fastest. Its REPL even writes the NUL into the stdin buffer to avoid an
    allocation (`main.zig:160-165`). Cost: callers must provide `[:0]`, and an embedded NUL ends
    the input.
  - *zirp* gave up the sentinel. Callers can then parse any slice (an editor buffer or a
    sub-range), and an embedded NUL can be reported instead of ending the file. Cost: a bounds
    check on every byte, and one missed spot that reads past the end (`Tokenizer.zig:458`; it is
    masked only because `main` zero-fills its buffer).
  - *inkz* never had a byte-level lexer that would profit from a sentinel; see §2.
- **No line table anywhere.** None of the three builds one. inkz planned a line-start table
  (§4.11) but computes position in O(offset) per diagnostic. That is acceptable only because
  diagnostics are capped at 256 and a compile stops at the first error. zirp has no
  line/column support at all; fino has no positions at all.

---

## 2. Lexing and tokens

| Choice | inkz | fino | zirp |
|---|---|---|---|
| Token stream exists? | **No.** Grammar rules scan characters themselves (`lexical.zig:1-3`) | Yes, pulled lazily one at a time (`Lexer.next`) | Yes, built eagerly for the whole file before parsing (`Parser.zig:183-194`) |
| State machine | None (no `continue :` anywhere in `src/`) | Labeled switch, 10 states (`Lexer.zig:88-295`) | Labeled switch, 47 states, re-enterable with a hint (`Tokenizer.zig:12-123`) |
| Stored token | `{start u32, end u32}`, **no tag**, SoA (`core.zig:52-53`), 8 B; only for leaves that need text | `{tag u6→u8, start u32, end u32}` = 12 B, by value, never stored | `{tag u8, offset u32}` SoA = **5 B**, **no end** |
| How a token's text is found | `start..end` | `start..end` | Re-lex from `offset` with a hint state (`Tokenizer.zig:65-110`) |
| Keywords | Matched by rules | `StaticStringMap` (12) | `StaticStringMap` (46) |
| Invalid input | Rule failure, then backtracking or a diagnostic | `.err` token; an unknown character **panics** (`Lexer.zig:203-205`) | Three graded invalid states: soft_invalid, invalid, poison-to-newline (`Tokenizer.zig:178-264`) |
| Pre-sizing | `(len/6 + 256) * scale` tokens | n/a | `len/8` (copied from std; dead path); in practice fixed huge reservations |

**Differences, why, and tradeoffs**

- **inkz has no tokenizer; the references both do.**
  - *Why:* ink is context-sensitive. Whether `-` starts a gather, `|` separates sequence
    elements, `[` opens a choice's bracket, or a line is a logic line depends on the enclosing
    rule, and InkParser itself is scannerless (`StringParser`). The plan wanted a mode-aware
    labeled-switch lexer (P7.1, D10). It was dropped because the faithful port (D13) needed the
    rule to choose how to read characters, and a separate lexer would have had to replicate
    InkParser's mode logic, a large source of divergence.
  - *Cost:* no byte-level hot loop for the compiler to tune, and character scanning is spread
    over many small rules. Backtracking re-scans characters a token stream would have scanned
    once. fino and zirp have unambiguous lexical grammars, so they can afford a separate,
    fast, labeled-switch lexer.
- **What a token stores is a deliberate three-way split.**
  - *zirp, 5 B (tag + offset):* this halves upstream's 2×`usize` `loc`, and slices are re-lexed
    on demand. That is cheap for Zig because a token's text is a deterministic function of its
    start state, encoded in `State.hint`. Cost: every slice re-runs the lexer, and the lexer must
    stay re-entrant mid-token (doc comments, multiline strings).
  - *fino, 12 B by value:* tokens are transient, consumed by the parser and never stored, so
    their size only matters for register pressure. Storing `end` costs nothing.
  - *inkz, 8 B (start + end, no tag):* the plan deliberately added `end` to zirp's design (the
    T2 deviation, 9 B), because re-lexing ink from a hint is context-dependent and a source of
    subtle bugs. The tag then turned out unnecessary: the node tag already says what kind of
    leaf a token is, and only leaves that need text record a token at all, about 0.04 tokens
    per byte against zirp's 0.17. Cost: none in practice. `Architecture.md:113` and
    `benchmarks.md:249` still describe a 9 B `{tag,start,end}` token and are stale.
- **Eager vs lazy vs on-demand.**
  - *zirp* lexes the whole file first, which gives unbounded `peek`/`nth` and parallel arrays
    that are kept in the Ast for tools.
  - *fino* pulls with two-token lookahead (`curr`, `peek`), the minimum its LL(1)-ish grammar
    needs, with no token array.
  - *inkz* records tokens during parsing; a failed rule truncates `tokens_count` back to its
    checkpoint. This is the only design of the three that is compatible with backtracking.
- **Resilience at the lexical level is zirp's alone.**
  - *zirp's graded skip* lets one bad character cost one `.invalid` token instead of the rest
    of the line, e.g. `🐊(32)` gives `.invalid, (, number, )` (`test_tokenizer.zig:586-588`).
  - *fino* panics on an unknown byte, which is acceptable for a toy and fatal for an editor.
  - *inkz* has no lexical error class. ink treats unrecognised text as content, so most of
    what other languages would call lexical errors are valid ink.

---

## 3. Parse control

| Choice | inkz | fino | zirp |
|---|---|---|---|
| Control | **Explicit frame stack**: `Machine(Grammar)` with step functions returning `Action{call, peek, succeed, fail, again}` (`core.zig:136-297`) | Recursive descent | Recursive descent (`grammar.zig:391-686`) |
| Backtracking | Yes, ink's: `Checkpoint{at, tokens, nodes, scratch, flags}`, restored on fail and after a peek | None | None (FIRST-set guards; "never fails") |
| Recursion bound | `parse_depth_max = 512` frames gives a `too_deep` diagnostic (`limits.zig:284`) | None | None (unbounded native stack) |
| Progress bound | Gas `64*(len+64)` gives a `no_progress` diagnostic (`core.zig:247-254`) | None | Gas only in `containerMembers`, which panics (`grammar.zig:111-181`) |
| Recursion enforcement | Lint: call-graph SCC (Tarjan with an explicit stack), one suppression in the repo (`tools/lint.zig:565-620`) | None; recursion everywhere | None |
| Rule dispatch | `switch (rule) { inline else => rule_function(rule)(…) }`; rules found by name at comptime across four modules (`grammar.zig:71-102`) | Direct calls | Direct calls; local labeled switches for sub-state (`grammar.zig:98-180`, `688-958`) |
| Precedence | Precedence climbing through frames, ink's table | Precedence climbing, `binOp` switch (`post_tree/Parser.zig:392-409`) | Precedence table parsed at comptime from a multiline string, scanned linearly (`grammar.zig:589-613`, `1064-1076`) |

**Differences, why, and tradeoffs**

- **Explicit stack vs recursion: the largest structural difference in the front end.**
  - *inkz* took zirp's node layout and recovery model but explicitly rejected its recursive
    grammar functions (plan §2, "Rejected"; D9). The reasons:
    - TigerStyle forbids recursion.
    - A game embedding a compiler cannot let a hostile or generated story overflow the native
      stack.
    - Ink stories nest deeply: weaves inside conditionals inside choices.
  - With the explicit stack, depth is a data-structure limit that turns into a diagnostic. The
    fuzzers (`docs/fuzzing.md`) can then run without a stack-overflow class of crash.
  - *Cost:* each InkParser method that can recurse becomes a rule with numbered `phase`s and
    three `u32` `locals`. Arguments and results move through `machine.argument`/`result`, the
    control flow is harder to read than recursive descent, and a lint has to police the rule.
    Per-frame overhead is a frame of about 36 B and an indirect `inline else` dispatch per step.
  - *fino and zirp* accept recursion for simplicity. For zirp this is a real exposure: an editor
    parser sees arbitrarily nested input, and the agent's probe showed `nosuspend` at top level
    loops pushing until the stack array is exhausted. For fino it is harmless at toy scale.
- **Backtracking (inkz only).**
  - *Why:* InkParser is a backtracking parser (`ParseObject`/`BeginRule`/`FailRule`), and
    matching its accept/reject decisions exactly is a correctness requirement (D13).
  - Because nodes, tokens and scratch are append-only arrays, a checkpoint is five `u32`
    counts and restoring is truncation. This is exactly the property zirp's scratch-stack
    design gives for free (T4).
  - *Cost:* rework on failed alternatives, and diagnostics must deliberately survive
    backtracking (the checkpoint has no diagnostics count).
  - *zirp* gets the opposite guarantee by construction: every production consumes at least one
    token if `atAny(FIRST)` holds (`grammar.zig:1088-1089`), so it never needs to backtrack.
    That only works for a grammar designed to be LL.
- **Comptime-built rule table (inkz) vs plain functions (refs).** inkz's comptime lookup turns a
    missing or duplicate rule into a compile error. That is the explicit-stack equivalent of
    "the call compiles", and it costs comptime and indirection that the references don't need.
- **Precedence.** zirp's comptime-parsed table is the most declarative. fino's switch is the
    simplest. inkz copies ink's table so it can reproduce ink's quirks. None uses a Pratt
    binding-power array indexed by tag, as upstream does; zirp's linear scan is marked "TODO
    this could be optimized!".

---

## 4. Tree construction and node layout

| Choice | inkz | fino: forest_pointer | fino: index_sea | fino: post_tree (live) | fino: moar_smaller | zirp |
|---|---|---|---|---|---|---|
| Storage | SoA `tags: []Tag(u8)`, `data: []u32` (`ast.zig:207-210`) | AoS heap nodes | AoS `[]Node` + `extra: []NodeIdx` | AoS `[]Node` | hand-rolled SoA `tags` + untagged `nodes` | SoA `tag: []Tag(u8)`, `repr: []packed union(u32)` |
| Bytes/node | **5** (comptime-asserted, `ast.zig:252-262`) | 32 + child slices | 20 (test claims 16 and is wrong) | 8 (test) | 5 in ReleaseFast, 9 in safe builds | **5** (enforced by `packed union(u32)`) |
| Child reference | `fixed(n)`: word = first of n contiguous children; `list`: word points at a `count` node, items follow (`ast.zig:171-242`) | `*Node`, `[]*Node` | `NodeIdx`, `Range{start, len}` into `extra` | **none**: implicit post-order, arity in tag/payload | none: implicit post-order | `first_child`; arity from the comptime schema |
| Variable-length lists | Inline **count node** prefix | slice | `extra` range | marker nodes (`scope_begin`/`scope_end` …) | marker nodes | Inline, ended by a **terminator leaf** or a tag-set miss (`Ast.zig:2534-2626`) |
| Optional child | Physical `none` node | `?*Node` | `NodeIdx.none` sentinel | absent / markers | absent / markers | Physical `.none` node |
| Missing required child | Physical `missing` node | n/a (error) | n/a | n/a | n/a | `.missing` node holding a `SyntaxError.Index` |
| Construction | Scratch stack + `wrap` memcpy (`core.zig:352-380`) | `arena.create` per node | Scratch `ArrayList` + copy to `extra` | Append in post-order; in-place rewrites | Append to two arrays | Marker stack + `wrap` memcpy + `pushUp` memmove (`Parser.zig:386-445`) |
| Main token | None; the leaf token is the word | n/a | n/a | n/a | n/a | None in the node; since `cf29122`, kept as an explicit **leaf child** for `for`/`while`/`switch`/block |
| Typed views | **Not built** (T6 planned) | Zig union | switch | `VariantType` | `@FieldType` | Comptime schema: `BranchNode`, `BranchNodeComplex`, `InlineListNode`, `UnionNode`, `toTyped` (`Ast.zig:2267-2749`) |
| Tags | 86 | union | union | 48 | 32 | 71, against upstream's 163 |

Measured densities:
- **fino** (bench.fino, 1M lines): moar_smaller **15.9 MB** AST, peak 33 MB; post_tree 25.5 MB;
  index_sea 53.1 MB; forest_pointer 86.4 MB, peak 289 MB (`benchmarks.txt`).
- **zirp vs upstream** on AstGen.zig: **1.82× more nodes, but 0.61× the bytes**, parse 1.22×
  slower.

**Differences, why, and tradeoffs**

- **5 B SoA nodes: inkz and zirp converge, and fino reaches the same size by another route.**
  - *zirp* stores `tag u8` with a `u32` that is a first-child index, a token, an error index, or
    nothing, with no `main_token`, no `extra_data` and no lhs/rhs.
  - *inkz* adopted it (T3).
  - *fino moar_smaller* reaches 5 B differently: there are no child links at all (post-order),
    and the payload is an untagged union. That size holds only in ReleaseFast; in safe builds
    Zig adds a hidden safety tag (`moar_smaller/Parser.zig:461-469`).
  - *Tradeoff:* fino's post-order is the densest and needs no indices, but you can only walk
    it forwards. You cannot jump to "the third child of node N" without a decode pass
    (`display.zig` rebuilds a tree with an explicit stack). zirp and inkz pay 4 B per branch
    for `first_child` and get random access to children. inkz needs that because sema expands
    objects from arbitrary nodes and resolves by node.
- **List encoding: count node (inkz) vs terminator (zirp) vs `extra` range (fino index_sea) vs
  markers (fino post-order).**
  - *zirp* stores the list's closing punctuation (`)`, `}`, `|`) as a leaf anyway, for tools.
    Using it as the terminator therefore costs no extra node. Cost: length and `lastToken` are
    O(n) scans, and a `.missing` node must be able to stand in for the terminator.
  - *inkz* lists have no closing token: ink's lines, weaves and sequence elements end by
    structure, not by a token. So inkz puts a `count` node in front (`wrap` writes it), giving
    O(1) length at the cost of one 5 B node per list. The spike planned list lengths in
    `extra`; inline count nodes avoid a second array and keep `wrap` a single memcpy.
  - *index_sea's* `Range{start, len}` in `extra` is upstream Zig's approach. It costs 8 B more
    per list node and an indirection, which is why fino moved past it.
  - *fino's* markers (`scope_begin`/`scope_end`, `fn_begin`/`fn_end` …) are the post-order
    analogue. They make the layout self-delimiting for a linear compiler, at the cost of
    ~29% more nodes (benchmarks.txt:8).
- **Optional children as physical nodes (inkz, zirp) vs a sentinel index (fino index_sea,
  upstream).**
  - A physical `none` keeps every fixed arity fixed. That is required when the child position
    is implicit (`first_child + i`), and it makes broken trees the same shape as good ones.
  - Cost: 5 B per absent child. zirp spends this on hot shapes and wins it back with
    `BranchNodeComplex`'s per-tag layouts (`expr_if` vs `expr_if_full`). inkz has no such
    optimisation: a choice is always `fixed(6)`.
  - fino's `NodeIdx.none` sentinel only works because index_sea references children by
    explicit index.
- **Construction by `wrap` (inkz, zirp) vs direct append (fino).**
  - `wrap` collects finished children as values on a scratch stack, then memcpys them into one
    contiguous run. zirp's reason is that children end up contiguous without knowing the arity
    up front, and nodes are written exactly once.
  - inkz has an additional reason: append-only arrays make backtracking a truncation (T4).
  - zirp also has `pushUp`, a memmove insert under a marker, to reorder children after the
    fact (O(siblings)). inkz never needs it, because its rules emit children in final order.
  - fino's post-order append is simpler still: no scratch, and the emission order is the
    storage order. That suits its grammar, where nothing is reordered. The exception is the
    in-place rewrites: index assignment `orderedRemove`s a node, which is O(statement), and
    move-on-last-use rewrites `get_var` to `take_var` (`post_tree/Parser.zig:239-277`). Here
    the parser doubles as an optimiser, mixing concerns that inkz keeps in separate passes.
- **Trivia and "attributes".** zirp keeps names, modifiers, doc comments and most punctuation
  as tokens only, recovered by scanning around anchor tokens (`Fn.attributes`,
  `Ast.zig:1139-1177`). That is minimal storage, but `firstToken`/`lastToken` get complex on
  broken trees. inkz stores the leaves sema needs as nodes and stores nothing a formatter would
  need, since there is no ink formatter. fino stores nothing positional.
- **Typed views: zirp has the most comptime machinery; inkz planned it and dropped it.**
  - zirp's schema maps struct fields to child slots and turns duplicate or unused tags into
    compile errors (`assertNodesUsedRecursive`).
  - inkz planned this (T6) but uses `shape(tag)` plus direct indexing; sema reads children
    positionally.
  - *Tradeoff:* inkz writes and compiles less code (`code_size.md` records the P13 cut), but
    child positions are magic numbers in sema rather than named fields. zirp's views make every
    downstream consumer safe against layout changes, which matters for a tree with 71 tags and
    several consumers (AstRlAnnotate, Render).
- **No `main_token` (zirp, inkz) vs upstream's always-present one.** Both drop it to save 4 B per
  node. zirp has begun adding it back *as a child leaf* where tools need it (`cf29122`), paying
  the 5 B only on those nodes. inkz has no need: diagnostics use the offset of the token at
  hand, and leaves carry their token.

---

## 5. Error recovery and diagnostics

| Choice | inkz | fino | zirp |
|---|---|---|---|
| Model | ink's: `expect_*` records and continues, `skip_to_next_line`, an `error_text` node (`grammar.zig:199-211`) | Fail fast: a Zig error propagates | **Never fails**: `expect` makes `.missing`, `skip` consumes one token, FIRST-set loop guards |
| Diagnostic record | `{code u8, offset u32, extra u32}` (`core.zig:23-39`); runtime 24 B structured | A single static `?[]const u8` | `SyntaxError{tag: unexpected / expected(token or other), token}` = 8 B |
| Cap | 256 compile, 32+32 runtime, with a dropped counter | 1 | 1024; overflow drops silently, and `missing()` then holds an out-of-range index |
| After an error | Compile stops (`CompileFailed`); diagnostics **not exposed** to callers | Stops | Tree is complete and typed; AstRlAnnotate returns empty |
| Message text | Rendered on demand from codes | Static string + `debug.print` | Codes only |

**Differences, why, and tradeoffs**

- **Resilience is zirp's purpose; for inkz it is mostly irrelevant.**
  - *zirp* serves editors, so a broken file must still give a full tree. Every slot is filled
    (`none`/`missing`), which keeps typed accessors total.
  - *inkz* compiles stories for shipping. A story with errors must not produce a `Program`, so
    resilience beyond ink's own recovery buys nothing at run time. The plan wanted zirp's model
    (T5); the port kept ink's model, because matching which diagnostics inklecate reports, and
    where, is part of compatibility.
  - inkz kept the *layout* parts of zirp's recovery (`none`/`missing` nodes, gas, depth limit)
    because they make the explicit-stack machine total.
  - *Cost to inkz:* no editor or LSP use without more work, and callers can't see diagnostics:
    `CompileFailed` is opaque (the `Result{program, diagnostics}` from plan §4.11 was not built).
- **Structured codes vs strings.** inkz and zirp store compact codes and render later, which
  keeps the hot path allocation-free and makes diagnostics testable by value. fino formats
  strings with `allocPrint` at the error site. That is simpler, but it allocates on the error
  path and, per the fino report, double-frees `vm.err` after a runtime error
  (`Program.zig:68-72`).
- **Caps.** inkz caps everything and counts drops (TigerStyle). zirp caps at 1024, but the
  overflow path is unsound. fino never needs a cap.

---

## 6. Middle end: semantic analysis, resolution, IR

| Choice | inkz | fino | zirp |
|---|---|---|---|
| Stages | parse → sema object tree → resolve → IR → layout → `ProgramBuilder` | parse → (pre-pass `collectFns`) → bytecode, **no IR** | parse → AstRlAnnotate (ported); AstGen/ZIR not ported |
| Object tree | SoA `sema.Tree`: kinds u8, flags u16 (bits shared per kind), parents, nodes, `children_first`/`count`, `children` (`sema.zig:103-112`), about 23 B/object | none | none |
| Resolution results | Side tables indexed by `ObjectIndex`: `targets`, `references`, a bitset, `item_values`, … (`resolve.zig:141-174`) | Inline in the compiler (`locals` stack) | `AutoHashMap(Node.Index, void)` (AstRlAnnotate) |
| Names | **Source slices** with Wyhash keys `{scope, name}` until the builder interns them | Interned `u24` from the parser on | `[]const u8` from tokens |
| IR | AoS `Stored` tagged union ≤ 24 B with side arrays; per-container **linked list** via `next`, then flattened (`lower_ir.zig`) | n/a | n/a (upstream ZIR in the copied AstGen) |
| Traversal | `Walk(comptime .pre/.post)`, one frame per level, 64 inline then spill (`sema.zig:244-262`) | post_tree: linear cursor + recursion per block; moar_smaller: one loop + backpatch stacks | Recursive (AstRlAnnotate, `firstToken`/`lastToken`) |
| Freeing | AST, object tree and resolution are freed before layout and emission (`compile.zig:36-60`) | AST freed after compile | Ast owned by the caller |

**Differences, why, and tradeoffs**

- **inkz has four middle stages; fino has none.**
  - *Why inkz:* ink's semantics are not syntax-directed. Weaves and gathers need structural
    analysis, divert targets resolve through scoped and relative names, and visit and turn
    counting must be decided per container. Lowering must also reproduce inklecate's container
    structure exactly, because paths, visit counts and saves depend on it (D2, D15). An object
    tree mirrors ink's `ParsedHierarchy`, which keeps the port checkable against the C# source.
  - *Why fino:* it is dynamically typed with function-level scoping, so a single pass with a
    `collectFns` pre-pass is enough. `moar_smaller` even compiles in one non-recursive loop over
    the tags array, the model inkz cites as T19.
  - *Cost to inkz:* memory and code. Mitigated by freeing early and by emitting by key instead
    of path strings, which made compiles 12–15% faster (P12.4).
- **SoA object tree vs AoS IR inside inkz.** The object tree is the read-mostly structure walked
    many times, so it is SoA. The IR is short-lived and heterogeneous, so a ≤ 24 B tagged union
    with side arrays was simpler. Its linked list per container avoids a buffer per container
    while generating, at the cost of pointer-chasing until it is flattened. Neither reference
    has a comparable structure; zirp's upstream AstGen uses SoA `MultiArrayList(Zir.Inst)` with
    `extra`.
- **Late interning (inkz) vs early (fino).**
  - *fino* interns in the parser, so AST payloads are `u24` ids that map 1:1 onto instruction
    operands.
  - *inkz* keeps slices into the source space through sema and resolve and interns only in the
    builder. That is because the JSON loader also feeds the builder, and the pool must be
    identical whichever producer runs (D7). Interning early would mean two interning sites with
    different rules.
  - *Cost:* name lookups during resolve hash strings rather than compare ids.
- **Traversal style.**
  - *inkz* lowers every walk to an explicit-level walker or a post-order layout, enforced by the
    lint (D9).
  - *fino* recurses per block in its live variant, and only `moar_smaller` is fully linear.
  - *zirp's* only consumer recurses, and `firstToken` was made recursive on purpose (commit
    "Make firstToken() recursive").
  - The `Walk` comptime order and in-place levels in inkz removed a measured 6%
    (`code_size.md:51-54`). The references never measured traversal cost separately.

---

## 7. String interning and constants

| Choice | inkz | fino | zirp |
|---|---|---|---|
| Pool | One `bytes` buffer + `ends: []u32`; id 0 = `""` (`string_pool.zig:15-28`) | `StringHashMap(u24)` + `ArrayList([]const u8)` + arena copies (`Interner.zig`) | None in the parser (upstream `string_bytes` in unported AstGen) |
| Hash set | `HashMapUnmanaged(u32 id, void, IdContext)`: keys are ids hashed through their bytes, with `BytesAdapter` lookup | Map keyed by slices | n/a |
| ID type | `StringId` `enum(u32)` newtype | raw `u24` | n/a |
| Freeze | `FrozenStringPool`, exact size, table moved (`string_pool.zig:144-157`) | Grows across REPL lines | n/a |
| Number constants | **Inline in the operand** (D14), no pool | `f64` pool, interned by bit pattern with ±0 and NaN canonicalised (`Interner.zig:5-18`) | n/a |
| Runtime strings | `StringReference` `enum(u32)`: bit 31 = heap offset, else program id | `*StrObj`, **reallocated on every literal execution** (`Vm.zig:430-438`) | n/a |

**Differences, why, and tradeoffs**

- **inkz uses the ZIR-style layout (T8); fino uses a slice list.**
  - *inkz:* `bytes + ends` is two allocations, contiguous, trivially serialisable into the
    program image, and an id is 4 B with no pointer. Hashing ids through their bytes means the
    table never duplicates a key. Cost: `intern` hashes twice (find, then insert), and the
    plan's tentative-append trick wasn't used.
  - *fino:* a `[]const u8` per string (16 B) plus arena bytes. Simple, but pointer-heavy and not
    serialisable, which fino never needs.
- **u24 ids (fino) vs u32 (inkz).** fino picks u24 so that an id fits exactly into
  `Inst.pld: u24`, one width end to end: AST payload, interner id, constant id, jump target.
  inkz has a full `u32` operand, so its ids don't need to shrink. Cost to fino: a 16M-entity
  cap, and overflow is caught only by `@intCast` in safe builds.
- **Constant pools.**
  - *fino* needs one because its numbers are `f64`, which doesn't fit 24 bits.
  - *inkz* numbers are `i32`/`f32`, exactly C# ink's (D14). They fit the 32-bit operand
    bit-for-bit (NaN preserved), so there is no pool, no indirection at run time, and one
    instruction per ink item.
  - *Tradeoff:* inkz's choice is tied to ink's 32-bit numerics. If ink ever had 64-bit
    numbers, inkz would need `extra` or a pool.
- **Runtime string identity.** inkz's tagged `StringReference` lets one 4 B field address either
  the immutable program pool or the movable heap, so literals never copy. fino allocates and
  duplicates a `StrObj` every time a string literal executes; the inkz plan names this as
  rejected.

---

## 8. Bytecode and program image

| Choice | inkz | fino | zirp |
|---|---|---|---|
| Instruction | `{opcode enum(u8) (80), operand u32}`, **SoA**, 5 B (`instruction.zig`; `sizes_test.zig:61-65`) | `packed struct(u32){op u8 (40), pld u24}`, **AoS**, 4 B (`Vm.zig:229-271`) | none (ZIR in unported AstGen) |
| Operand typing | Comptime `operand_kind(opcode)`, exhaustive with no `else`; `init(comptime op, typed)` and `get(comptime op)` | Raw `u24`; sub-packed `CallPayload`, `IterPayload{n u4, exit u20}` | n/a |
| Wide operands | `extra: []u32` with typed `ExtraIndex(T)` records and `packed struct(u32)` flags; `decodable` validates untrusted words (`extra.zig`) | None; everything fits in 24 bits | n/a |
| Code organisation | **Containers**: each one a contiguous instruction range; nesting via `enter_container`; parents have lower indices (D2) | One flat array; functions inline behind a `jmp` | n/a |
| Control flow | `{container, index}` pointers; divert records in `extra` | Absolute `u24` pc jumps, backpatched by index | n/a |
| Persisted form | Binary image: 40 B header, 22 sections, layouts pinned at comptime, validated on load; 1.4× the JSON size, 18–20× faster to load (`program_image.zig`) | None (REPL accumulates `insts`) | n/a |
| Producers | Two: the JSON loader and the compiler, both through `ProgramBuilder` | One | n/a |

**Differences, why, and tradeoffs**

- **4 B AoS packed (fino) vs 5 B SoA (inkz).**
  - *fino:* one 4 B fetch per instruction with no SoA column math, so it is cache-optimal for a
    linear pc-driven VM. Cost: 24-bit operands cap everything at 16M, and wide data has to be
    packed into sub-fields (`u20` loop exits cap at 1M instructions).
  - *inkz (D1):* a full `u32` operand holds `i32`/`f32` literals and every index without
    packing. SoA keeps the opcode column dense: 1 B per instruction for scans such as the
    image loader's `[256]bool` opcode check. Cost: two column reads per fetch, plus a container
    base lookup (`program.zig:124-138`), and 5 B can't be fetched as one aligned word.
- **Containers vs a flat pc.**
  - *inkz* keeps ink's container model (D2): visit counts, turn counts, `CHOICE_COUNT`, saves,
    `choose_path_string` and divert-target values are all defined by container and index.
    A flat pc would need a reverse map for every one of those. Full linearisation was a stretch
    goal gated by benchmarks, and it was never taken.
  - Cost: a two-level address and `enter_container` pseudo-instructions. One ink item is one
    instruction, which keeps indices exactly as in ink's JSON.
  - *fino* has no externally visible addresses, so absolute jumps with backpatching are optimal.
- **Typed operands.** fino's raw `u24` relies on the compiler and VM agreeing by convention.
  inkz's comptime `operand_kind` table makes a mismatched operand a compile error and makes
  operand decoding total for the image validator. That costs a comptime table and generic
  init/get, and it is what lets inkz load untrusted images safely.
- **A persisted image is inkz-only.** A game ships compiled stories, so load speed and robustness
  against hostile input matter. The image trades 40% more bytes for 18–20× faster loads, and
  validation stays on by default. fino and zirp are in-process tools with nothing to ship.

---

## 9. VM and dispatch

| Choice | inkz | fino | zirp |
|---|---|---|---|
| Dispatch | `while (taken < budget) step()` loop; `perform` = range check to natives, then a plain `switch` (`vm.zig:88-346`) | **Labeled switch threaded**: `continue :loop vm.trace(next(&pc, insts), pc)` (`Vm.zig:416-726`) | n/a |
| Native ops | Runtime double switch: common type, then opcode (`native.zig:100-121`) | `inline .add, .sub, … => \|op\| binop(op)` with comptime op | n/a |
| Fetch | `instruction_first[c] + i` → 2 SoA columns | `insts[pc]`, a 4 B word | n/a |
| Step budget | 1,000,000 per `cont()` → `error.StepLimit` | None | n/a |
| Tracing | n/a (profile zones gated at comptime) | `trace_enabled = true` **on in the latest commit**, prints every instruction | n/a |

**Differences, why, and tradeoffs**

- **The plan wanted fino's VM; inkz didn't build it.** T12 and D10 called for labeled-switch
  threaded dispatch with comptime-opcode prongs, and D10 reserved one of the two 70-line lint
  exceptions for it. It is unused: there are zero `function_length` suppressions.
  - *Why it doesn't pay in inkz:* fino executes a tight arithmetic language, so dispatch is most
    of the cost of an instruction. An inkz step does far more per instruction: it enters
    containers, resolves pointers, counts visits, appends to the output stream, and takes a
    lookahead snapshot at newlines. P12.3 halved how often `vm.run` returns to the Continue
    loop, and it bought only 0–2% "because the time is in the steps themselves"
    (`benchmarks.md`). Threaded dispatch would mostly remove a branch mispredict that is not
    the bottleneck.
  - *Tradeoff:* inkz keeps every function at 70 lines or fewer and each prong a helper call,
    easier to audit under TigerStyle, and gives up the last few percent of dispatch speed.
    fino's single large function with `inline` prongs maximises speed and accepts a function
    of about 300 lines.
- **The step budget (inkz)** makes `cont()` terminate on any story, including a divert loop.
  A host game can't hang. fino's REPL hangs on an infinite loop, which is acceptable there.

---

## 10. Values, stacks and frames

| Choice | inkz | fino | zirp |
|---|---|---|---|
| `Value` | `union(enum(u8))`: null, i32, f32, bool, `StringReference`, `ContainerIndex`, variable_pointer `{StringId, i32}`, `ListReference`, tag; **12 B**, asserted (`value.zig:67-117`) | `union(enum)`: nil, taken, idx usize, f64, atom u24, `*StrObj`, `*ArrayObj`, `*RecordObj`; **16 B** | n/a |
| Evaluation stack | `BoundedStack(Value)`, 1024 by default, shared across flows | `ArrayList(Value)`, `try append` per push | n/a |
| Call stack | **Flat**: all threads' frames in one array, each thread a range; `Frame` 24 B, `Thread` 20 B (`call_stack.zig`) | `ArrayList(Frame{ret_pc, saved_frame_base})` 16 B, **allocated per `interpret`** | n/a |
| Locals | Temps: per-frame `{StringId, Value}` 16 B, **linear scan by name**, ≤ 256 per frame (D3) | **Compile-time slots** in the operand stack at `frame_base + slot` | n/a |
| Globals | Slot-indexed array, but reads go `slot → name → global_slot(name)`, a linear scan over all globals (`ops.zig:436-513`) | `array_hash_map(u24 name → Value)`, a hash lookup per access (`Vm.zig:344`) | n/a |

**Differences, why, and tradeoffs**

- **12 B indexed values vs 16 B pointer values.**
  - *inkz:* every payload is a 4 B index or scalar, so a `Value` is pointer-free and therefore
    `memcpy`-safe across snapshots, flow parking, saves and heap compaction. Compaction only
    has to rewrite references, never raw pointers. 32-bit numerics (D14) keep it at 12 B.
  - *fino:* `f64` numbers and raw heap pointers force 16 B. A pointer makes access direct, with
    no base addition, and refcounting operates on the pointee. But the objects can never move,
    because they are individually `gpa.create`d.
- **Bounded vs growing stacks.** inkz preallocates everything (§12). fino does `try append` on
  every push, which is an allocator check in the hot loop and an error path on every
  instruction. The inkz plan lists both of fino's "per-push `try append`" and "per-call
  `call_stack` allocation" as rejected.
- **Flat call stack with threads as ranges (inkz only).** ink's threads (`<-`) fork the whole call
  stack, and choices snapshot their thread. In a flat array a fork is one range copy
  (`copy_frames`), and consecutive identical snapshots are shared in `choices.zig`. fino has no
  threads, so frames are a simple stack.
- **Name-scanned temps and globals (inkz) vs compile-time slots (fino).**
  - *Why inkz:* ink's semantics require it. Variable pointers (`ref` parameters) carry a name and
    a context index (`VariablePointer{StringId, i32}`), temps can be shadowed across frames,
    and `raw_variable` must reproduce `GetRawVariableWithName`'s precedence: globals, then
    single-item lists, then temps (`ops.zig:445-455`). D3 deliberately chose a bounded linear
    scan, because frames hold few temps.
  - *Cost:* every global read is O(globals). A `temp_get` at context −1 additionally does a
    `strings.find` (Wyhash) and a list-item scan. These are hot-path costs in `ops.zig`, which
    the `hot_path` lint (it only checks `vm.zig`) doesn't see. This is the largest remaining
    DOD gap in the inkz runtime: it could resolve the global-slot fast path when the name is
    known to be a global, since the compiler already resolves the slot.
  - *fino* resolves locals to slots, the fastest possible, but leaves globals as a run-time
    hash keyed by name, because REPL lines can define globals later.

---

## 11. Heap and memory management of runtime objects

| Choice | inkz | fino | zirp |
|---|---|---|---|
| Strategy | Fixed string heap + list slab; **sliding mark-compact** when an allocation fails (`heap.zig:145-310`) | Per-object `gpa.create`, **refcount + copy-on-write + move on last use** | n/a |
| Object header | String `[length\|mark bit31, forward, bytes, pad]`; list `[forward, items_count, origins_count, …]` | `rc: u32` + payload | n/a |
| Order | Allocation order preserved, so heap marks and lookahead tops stay valid | n/a | n/a |
| Value semantics | Ink strings and lists are immutable values: every op produces new objects | Mutable value semantics: COW when `rc > 1`, in place when `rc == 1` (`Vm.zig:37-79`) | n/a |
| Lists | Ordered item arrays, **linear membership scan** (`lists.zig:1-12`) | `ArrayList(Value)` | n/a |

**Differences, why, and tradeoffs**

- **Mark-compact (inkz) vs refcount/COW (fino): explicitly decided (D4, T17 rejected).**
  - *inkz's reasons:*
    1. RC/COW needs a general allocator or a free list, and that breaks "no allocation after
       init".
    2. RC traffic (retain on every read) sits on the hot path.
    3. A sliding compactor preserves order, so the lookahead snapshot can record "heap top =
       N" and restore by truncating, which is how D12 stays cheap.
    4. A fixed heap is defragmented by construction.
  - *Costs to inkz:* a GC pause when the heap fills. It is bounded by the heap size, but
    nonzero, and stress-tested with `compact_always`. In-flight operands need `keep` roots.
    There is no in-place mutation, which ink doesn't need anyway since its strings and lists
    are immutable values.
  - *fino's reason:* its whole research question is mutable value semantics. COW plus
    move-on-last-use (parser rewrite `get_var → take_var`, compiler `take_*`/`put_glob`, VM
    `.taken`) makes `x = append(x, v)` O(1) in place.
  - *Costs to fino:* an allocation per object, recursive `release`/`eql`, retain on every read,
    and no cycle collection. Cycles can't form under value semantics, so the last one doesn't
    matter.
- **Lists: ordered arrays (inkz) vs bitsets (inkz's plan).** The plan (§4.4) wanted fixed-width
  bitsets plus an order array. The code keeps ordered item arrays with linear scans, because
  ink's `LIST_RANDOM` and min/max tie-breaking depend on insertion order (D15 amendment), and
  ink lists are small. The cost is O(n·m) set operations, invisible at ink scale.

---

## 12. Allocation strategy, budgets and ownership

| Choice | inkz | fino | zirp |
|---|---|---|---|
| Runtime | **One** `alignedAlloc(bytes_total)` carved by a `Carver` with `used == len` asserted (`state.zig:~305-317`), plus a `bindings` slice (so 2 allocations in `Story.init`) | gpa everywhere: stacks, frames, objects | n/a |
| Budget | `Limits` (all `u32`) → exact `bytes_total()` from `element_bytes` (`limits.zig:12-174`); about 2.2 MB by default, 40–50 KB when fitted | none | n/a |
| After init | **Zero allocations**, gated by a comptime `has_no_allocator(Story/State)` and a counting-allocator run of every ground-truth case | Unbounded | n/a |
| Parser | Workspace sized from the source; overflow → **re-parse at 2×** up to 3 times; `settle` reallocs down (`core.zig:61-99`) | ArrayLists (gpa) or an arena (forest_pointer) | **Caller reserves**; parser never grows; `createAst` dupes exact-size slices; parser reusable ("erase data, retain capacity") |
| Growth on overflow | Restart (T15) | Implicit (ArrayList) | Designed (`oomed` → `reserveMore` → retry), but **disabled** (`if (true) @panic("ooms")`) |
| Compiler middle | ArrayLists/hash maps on the gpa | gpa | gpa + arena (AstRlAnnotate) |
| Overflow behaviour | Named limit errors (`BoundedStack` → `error.Overflow` → named), with peaks recorded for `Limits.fitted` | OOM only | Panic |

**Differences, why, and tradeoffs**

- **Static budget at run time is inkz's defining choice.**
  - *Why:* a game needs predictable memory, no allocator in the frame loop, and the ability to
    run many stories side by side. TigerStyle demands it, and fitted limits shrink a story to
    tens of KB.
  - *Costs:* every buffer needs a limit, an overflow error and a peak counter. Hosts must size
    limits, or accept 2.2 MB of defaults. Some limits are ink-visible (temps per frame, heap
    bytes), so a story that runs in C# ink can hit a limit in inkz. Benchmarks show the budget
    doesn't affect speed.
  - *fino and zirp* have no runtime-embedding requirement.
- **Parser preallocation: three strategies.**
  - *zirp:* exact caller-supplied capacities, and a reusable parser. That gives the best
    steady state for an editor re-parsing the same file. But the growth path doesn't work, so
    in practice callers over-reserve by orders of magnitude (`main` reserves about 450 MiB).
  - *inkz:* adapted the same idea (T15). It estimates from source length, restarts at double
    size on overflow, then trims. Compilation is init-phase, so allocation is allowed there.
    A restart costs a full re-parse, measured at 32% of a large compile until P12.2 retuned the
    estimate. In-place growth was avoided because the workspace slices are referenced
    throughout the machine.
  - *fino:* ordinary growing ArrayLists. That is the simplest, and the variants were measured
    by peak footprint (§13), where `forest_pointer`'s arena and its 255-pointer `initCapacity`
    per function cost the most (289 MB peak).
- **Ownership hand-off.** zirp copies out an exact-size Ast and keeps its buffers. fino
  `toOwnedSlice`s the ArrayList. inkz `settle`s (reallocs down) in place and frees whole stages
  as soon as the next one no longer needs them. All three end with a right-sized result; they
  differ in whether the working buffers survive for reuse (zirp) or are given up (fino, inkz).

---

## 13. Lookahead, flows and saves (inkz only)

Neither reference has these. They are listed because they shape choices made elsewhere.

- **Lookahead snapshot plus undo log (D12).**
  - `cont()` must return exactly one line, which requires running ahead to see whether more
    text glues on.
  - The snapshot memcpys the *used prefix* of 11 live-flow buffers. Writes to shared arrays
    (globals, visit counts, turn indices) are logged at most once per slot, through a
    `patch_logged` bitset, as `PatchEntry{target u32 (2-bit kind + 30-bit slot), old Value}`
    at 16 B each.
  - Restore copies the buffers back, undoes newest-first, and truncates the heap.
  - *It is why* values are pointer-free (§10), the compactor preserves order (§11), and the
    budget contains a second copy of the live-flow buffers (§12).
- **Flow parking.** Only the current flow is live. Parked flows are packed as `u32` words with an
  `extern` header into a 256 KiB region, and every flow element is asserted to be 4-byte
  aligned and a multiple of 4 B.
- **Saves.** Ink v10 JSON, both ways (D15). `save` streams to a writer without allocating.
  `load` tokenises into a fixed `json_tree.Node[]` (16 B, with a `next` subtree-end link for
  O(1) skip), validates in one pass and commits in a second, so a failed load changes nothing.

---

## 14. Host API and lifetimes

| Choice | inkz | fino | zirp |
|---|---|---|---|
| Consumer | Host game via a library API | REPL/CLI | Library `Ast` + CLI benchmarks |
| Returned data | `Borrowed(T){value, stamp}`; the stamp is `{generation, *const u32}` in safe builds, empty otherwise (D5) | Printed | `Ast` slices owned by the caller |
| Callbacks | `context: ?*anyopaque` everywhere (D22); re-entrancy gives `error.Reentrant` | builtins as `NativeFn` | n/a |
| Enumeration | Sinks (`sink.tag(text)`) instead of slices | n/a | Iterators (`NodeIterator`, `TokenIterator`) |

**Differences, why, and tradeoffs.** inkz returns views into its fixed buffers instead of
copies, so `cont()` allocates nothing, and checks lifetimes with generation stamps, but only in
safe builds. The cost is an API where any mutating call invalidates earlier views. zirp's Ast
is immutable once built, so its slices and iterators never go stale. fino hands nothing to a
host.

---

## 15. Index newtypes, sentinels and bit packing

| Choice | inkz | fino | zirp |
|---|---|---|---|
| Index newtypes | **Everywhere**: `Index(name)` = `enum(u32){none = maxInt, _}` with comptime asserts; 11 core + 3 compiler (`core/index.zig`) | Only index_sea (`NodeIdx`, `ExtraIdx`); otherwise raw `u24`/`usize` | `Node.Index` (`root = 0`), `Token.Index`, `SyntaxError.Index`, `Marker`; no `OptionalIndex` |
| `usize` in structs | Forbidden by lint (`usize_field`) | Common (`pc`, `frame_base`, `Value.idx`) | `u32` throughout |
| Absence | `none = maxInt` per type; many named sentinels (`no_count_slot`, `never_visited = minInt(i32)`, …) | `NodeIdx.none`, `Value.taken`, the hidden-slot `maxInt(u24)` | Physical `.none` nodes; out-of-range token index reads as `.eof` (`Ast.zig:688-715`) |
| Packed fields | `packed struct(u32)` flags, `ContainerFlags u8`, mark bit in the heap length, heap bit in `StringReference`, `PatchEntry` 2+30 | `packed struct(u32)` Inst, `(u24)` sub-payloads, `u4`/`u5` payload fields | `packed union(u32)` Repr, `TagSet` = `@Int(.unsigned, n)` bitsets |

**Differences, why, and tradeoffs**

- **Uniform newtypes (inkz) vs raw integers (fino) vs a partial set (zirp).**
  - inkz applies T1 everywhere, because its data crosses many tables: containers, strings,
    globals, list items, flows. Mixing up two `u32`s is the bug class the newtypes exist to
    remove, and they double as the `none` encoding. Cost: verbosity (`.from_int`, `.to_int`),
    and every `to_int` asserts not-none.
  - fino's u24 everywhere relies on one width meaning "an id" throughout, and has no
    protection.
  - zirp types its main indices but keeps the clamp-to-eof semantics. That makes broken trees
    safe to query, at the cost of silently reading `.eof` on an out-of-range index.
- **Physical absence (zirp, inkz AST) vs sentinel absence (inkz elsewhere, fino).** Inside the
  AST, the slot position is implicit, so absence must occupy the slot. Everywhere else an
  explicit index field exists, so `maxInt` is free.

---

## 16. Invariants, safety and engineering rules

| Choice | inkz | fino | zirp |
|---|---|---|---|
| Size guards | `comptime assert(@sizeOf(T) == limits.element_bytes.x)` next to every type, plus `sizes_test.zig` with `soa_bytes(T)` | Runtime tests only; index_sea's is wrong | None (packed widths only) |
| Structural checks | `check() → Fault` enum + `verify()` that panics **in every build mode**; death tests run in child processes (`tools/death.zig`) | `debug.assert` | `assert` in accessors, `maybe()`, comptime schema exhaustiveness |
| Lint | `tools/lint.zig`: function ≤ 70 lines, line ≤ 100 columns, recursion SCC, no `usize` fields, snake_case files, ≥ 1 assert per function, `hot_path` text bans in `vm.zig` | None | None |
| Release mode | ReleaseSafe ships (D11) | ReleaseFast | ReleaseFast |
| Comptime metaprogramming | `operand_kind` table, `rule_function` lookup, `Walk(order)`, image `record_layouts` | `@FieldType`/`@unionInit` constructors, `inline` op prongs | `TagSet`, `SyntaxTag` = `@Enum(u16, Token.Tag ++ Node.Tag)`, schema reflection, comptime precedence table |

**Differences, why, and tradeoffs**

- **TigerStyle (inkz) vs research code (fino) vs research-grade library (zirp).**
  - inkz runs inside someone else's process on story data it didn't write. So it asserts
    densely, keeps asserts on in shipping builds, and verifies loaded images and saves.
  - *Cost:* ReleaseSafe overhead, accepted (performance targets are set for ReleaseSafe), and
    a large code base: about 39K lines against fino's 8K and zirp's ~8K of its own code.
- **A size measured only in ReleaseFast is a trap.** fino's moar_smaller is 5 B per node only in
  ReleaseFast, because untagged unions carry a hidden safety tag in safe builds. inkz ships
  ReleaseSafe, so it uses a tag column with a plain `u32` data column, never untagged unions,
  and its sizes are the same in every mode. zirp uses `packed union`, which has no safety tag,
  and gets the same property.
- **Comptime exhaustiveness.** zirp spends comptime on making the *tree schema* total. inkz
  spends it on making *instruction operands* and *image layouts* total. Each protects its most
  consumed interface: zirp's is the Ast, inkz's is the Program.

---

## 17. Testing and measurement of DOD properties

| Choice | inkz | fino | zirp |
|---|---|---|---|
| Ground truth | C# ink v1.2.1 harness outputs (D13, D19); structural gate `load(serialize(compile(src))) == compile(src)` | Its own tests | Parses all of std; snapshot corpora |
| Snapshots | (Ground-truth transcripts) | none | `.ast.zon` + `SNAP_UPDATE=1`; correctness and resilience corpora; `zirp-error` line markers; examples inside `grammar.zig` |
| DOD gates | Zero-allocation gate, exact-budget test, size asserts, `Limits.fitted` from peaks | AST size per variant (`-astsize`) | `--compare-std` (nodes, bytes, time) |
| Benchmarks | `bench` / `bench-io` / `bench-profile` (JSONL, comptime profile zones, CPU counter), in ReleaseSafe and ReleaseFast | hyperfine + `time -l` + perf counters (IPC, cycles) per variant | `--compare-std`, `--bench-*` (AstRlAnnotate × 10k) |
| Fuzzing | One target per pipeline stage, structure-aware ink generation, ReleaseSafe | none | Tokenizer fuzz (`std.testing.fuzz` + `Smith`) |
| Simulation | 183 cases × 10k seeds, plain and `compact_always` | none | none |

**Differences, why, and tradeoffs.**
- fino measures *hardware effects* (IPC, cycles, peak RSS) because its question is which layout
  is faster. Its finding: layout moves cycles more than instructions.
- zirp measures *against upstream*, because its claim is "smaller than std.zig.Ast".
- inkz measures *conformance first*. Its correctness bar is someone else's implementation, so
  ground truth, round-trip gates and simulation dominate, and performance work had to show
  no ground-truth regressions.
- inkz's zero-allocation gate turns a design rule into a test, which no reference does.

---

## 18. Technique lineage: what inkz took, and what happened to it

The migration plan (`docs/DODMigrationPlan.md` §2) lists 19 techniques taken from the
references. This is where each one stands in the code today.

| # | Technique (source) | Status in inkz | Why |
|---|---|---|---|
| T1 | `enum(u32){none=maxInt,_}` newtypes (fino index_sea, zirp) | **Adopted**, everywhere | Many cross-referencing tables |
| T2 | 5 B `{tag, offset}` tokens (zirp) | **Changed**: `{start, end}` 8 B, no tag, on-demand | Re-lexing ink is context-dependent; the node tag already types the leaf |
| T3 | 5 B node, packed u32, contiguous children (zirp) | **Adopted**, plus count-node lists | ink lists have no closing token |
| T4 | Scratch stack + `wrap` (zirp) | **Adopted** (no `pushUp`) | Append-only arrays make backtracking free |
| T5 | Never-fail grammar, `.missing`, gas, FIRST invariant (zirp) | **Partial**: `none`/`missing`, gas and depth limit kept; ink's recovery model kept instead | Diagnostic parity with inklecate |
| T6 | Comptime typed views (zirp) | **Not built** | Code-size reduction; sema indexes positionally |
| T7 | `TagSet` bitsets (zirp) | **Not built** | No token tags to put in a set; rules scan characters |
| T8 | ZIR `string_bytes` + id-keyed set (AstGen) | **Adopted** (`bytes + ends`); tentative-append not used | Serialisable, pointer-free |
| T9 | `extra` encode/decode (AstGen) | **Adopted**, plus `decodable` validation | Untrusted images |
| T10 | Shared scratch for nested bodies (GenZir) | **Adopted** in `ProgramBuilder` | Nested containers |
| T11 | Fixed opcode+operand instruction (fino) | **Adopted, widened** to u8 + u32 SoA | i32/f32 inline, no pool |
| T12 | Labeled-switch threaded VM (fino) | **Not built** | Time is in step bodies (P12.3: 0–2%) |
| T13 | Comptime-typed instruction constructors (fino) | **Adopted** (`init(comptime op, …)`) | Operand safety |
| T14 | `@sizeOf` guards (fino) | **Adopted**, stronger: comptime and tied to the budget | Budget arithmetic depends on them |
| T15 | Reserve, flag overflow, retry doubled, copy exact (zirp) | **Adopted** as restart-at-2× + `settle` | zirp's own growth path is disabled |
| T16 | Side tables keyed by index (zirp AstRlAnnotate) | **Adopted** (resolve tables by `ObjectIndex`) | Sema results |
| T17 | Refcount + COW (fino) | **Rejected** (D4) | Allocator on the hot path; lookahead needs order-preserving heap |
| T18 | Snapshot corpora (zirp) | **Not adopted as such**; ground-truth transcripts instead | The C# harness is the oracle |
| T19 | One-pass non-recursive post-order compile (fino moar_smaller) | **Adapted**: post-order walks per stage, not one pass | ink needs sema and resolution before lowering |

---

## 19. Findings: what deserves changing in inkz

Phase 16 (`docs/Phase16Plan.md`) addressed every finding; the last column of the summary
says how. The sections below are the findings as they were found, at `9018c6d`.

Every finding below was checked against the code at `9018c6d`. Severity rates the effect on
inkz's own goals (bounded memory, hot-path cost, correctness of claims), not how much work the
change is. Each finding comes with a success criterion that a unit test can check, as
`CLAUDE.md` requires for issues.

### Summary

| ID | Severity | Area | Finding | Proposed change | Status after Phase 16 |
|---|---|---|---|---|---|
| F1 | <span class="sev high">High</span> | Runtime perf | Every `temp_get` scans all globals, hashes the name and scans every list item before it reaches the temps | A per-`StringId` name-class table built with the Program | **Fixed** (P16.9): `Program.name_classes`; no name lookup by text while playing |
| F2 | <span class="sev high">High</span> | Runtime perf | `global_get`/`global_assign` with a resolved slot go slot → name → linear scan | Read and write `state.globals[slot]` directly | **Fixed** (P16.8): globals read and written through their slot |
| F3 | <span class="sev high">High</span> | Lint / claims | The "no hashing in the hot path" gate covers `vm.zig` only, so F1 and F2 slip through and `benchmarks.md:247` is untrue | Extend `hot_path` to every file the step reaches, and ban `strings.find` and `*_by_name` | **Fixed** (P16.7): the lint covers every file the step reaches |
| F4 | <span class="sev med">Medium</span> | Runtime memory | `Story.init` makes two allocations; four docs say one | Carve `bindings` from the budget | **Fixed** (P16.10): the bindings are carved from the one block |
| F5 | <span class="sev med">Medium</span> | Compiler API | Diagnostics never reach callers (`CompileFailed` is opaque) | A diagnostics result or a sink | **Fixed** (P16.12): `Options.diagnostics`, inklecate's messages, ground truth |
| F6 | <span class="sev med">Medium</span> | Compiler | Line/column is O(offset) per lookup, and the file lookup is a linear scan | A line-start table per file | **Fixed** (P16.11): a newline table and a binary file search |
| F7 | <span class="sev med">Medium</span> | Compiler code | Sema reads AST children by magic position (T6 not built) | Named slot constants per `fixed(n)` tag, comptime-checked | **Fixed** (P16.13): `ast.slot(node, .label)`, checked at compile time |
| F8 | <span class="sev med">Medium</span> | Docs | Token layout documented as `{tag, start, end}` 9 B; real is `{start, end}` 8 B | Fix `Architecture.md:113`, `benchmarks.md:249` | **Fixed** (P16.20): docs say `{start, end}`, 8 B; a test pins it |
| F9 | <span class="sev med">Medium</span> | Docs | Guidelines say scanners and VM dispatch are labeled switches; neither is | Rewrite `Guidelines.md:195-200` to match the code | **Fixed** (P16.20): Guidelines describe the scannerless grammar and the plain switch |
| F10 | <span class="sev low">Low</span> | Safety | No size guards for parser `Frame`, `Checkpoint`, compiler `Diagnostic`, IR `Stored` | Comptime `@sizeOf` asserts + `sizes_test.zig` rows | **Fixed** (P16.14): size asserts and `src/compiler/sizes_test.zig` |
| F11 | <span class="sev low">Low</span> | Safety / docs | "No pointers in persistent data" is enforced by convention only | Comptime `has_no_pointers` over flow, snapshot and parked element types; scope the rule in the docs | **Fixed** (P16.14): `pointer_free.has_no_pointers` on the copied types |
| F12 | <span class="sev low">Low</span> | Compiler perf | `StringPool.intern` hashes a new string twice | One adapted `getOrPut` | **Fixed** (P16.15): one hash per `intern` |
| F13 | <span class="sev low">Low</span> | Compiler perf | Resolve keys hash name slices (`{scope, []const u8}`) | Intern names at sema build, so keys are `{ObjectIndex, StringId}` | **Decided by measurement** (P16.16): under 1% of a compile; keys stay |
| F14 | <span class="sev low">Low</span> | Compiler perf | A workspace overflow re-parses the whole story at 2× | Keep it, but gate "no retry" on the test corpus | **Fixed** (P16.17): retries counted, gated at 0 on the corpus, in the bench |
| F15 | <span class="sev low">Low</span> | Runtime perf | Native binary ops dispatch on opcode at run time | Measure comptime-opcode prongs (fino) before deciding | **Decided by measurement** (P16.18): comptime prongs built and measured no faster |
| F16 | <span class="sev low">Low</span> | Docs | The migration plan reads as the current design, but T2/T6/T7/T12, §4.4 and §4.11 were changed or not built | Add an "as built" column (§18 of this doc) | **Fixed** (P16.20): the plan has an As built column and a deviations list |
| F17 | <span class="sev low">Low</span> | Runtime perf | Images are always validated on load, including images just built in-process | Optional trusted path, behind an explicit API | **Fixed** (P16.19): `program_image.load_trusted`, about 3× faster in ReleaseFast |
| F18 | <span class="sev low">Low</span> | Runtime perf | Save load is two passes (validate, commit), ~45% each | Keep for atomicity; revisit only if save load shows up in a profile | **Decided** (P16.18): two passes kept; one pass can't stay atomic |

### F1: every temp read goes through globals and list items first

- **Evidence.**
  - `temp_get` calls `ops.temp_value`, which calls `variable_value(name, -1)` (`vm.zig:455`,
    `ops.zig:516-518`).
  - That calls `raw_variable`, which for context −1 first runs `global_slot(name)`, a linear scan
    over `program.globals` (`ops.zig:436-449`).
  - Then it runs `single_item_list(name)` (`ops.zig:450`, `483-491`). That calls
    `strings.get`, then `program.list_item_by_name`, which does `strings.find` (Wyhash) and then a
    linear scan over all list items (`program.zig:377-384`).
  - Only after all that does it reach `stack.temp_get` (`ops.zig:454`).
  - `assign_temp` runs `global_slot` on every assignment too (`ops.zig:577`).
- **Why it matters.** Temps are the most common variable reads in function-heavy ink. Each one
  costs O(globals) + a hash + O(list items). This is the only remaining per-instruction string
  hashing in the runtime, and fino's compile-time slot resolution shows the cost can be zero.
- **Proposed change.** The Program is immutable, so classify each name once:
  - Add `name_classes` to `Program`: a dense array indexed by `StringId`, 4 B each, saying
    "global slot N", "list item N", or "neither". The builder fills it, and the image stores it
    or rebuilds it on load.
  - `raw_variable` then does one array read instead of two scans and a hash. The lookup order,
    and with it ink's `GetRawVariableWithName` semantics, stays the same.
  - Alternative: the compiler emits a `temp_get_unshadowed` variant when sema proves the name is
    neither a global nor a list item. That is smaller, but it has to be done separately for the
    JSON loader path.
- **Success criterion.** A unit test plays a story with 200 globals and 200 list items through
  a `temp_get` loop, counting calls with a test hook on `strings.find` and `global_slot`. Both
  counts must be 0 during play. Ground-truth transcripts must be unchanged.

### F2: resolved global slots are thrown away

- **Evidence.**
  - `global_value(slot)` reads the slot's name, then calls `variable_value(name, 0)`, which runs
    `raw_variable`, which runs `global_slot(name)` to find the slot again (`ops.zig:507-513`,
    `445-449`).
  - `assign_global(slot)` passes the name to `assign_existing` the same way
    (`ops.zig:567-571`).
- **Why it matters.** It is O(globals) per read, for an index the compiler already resolved and
  stored in the operand.
- **Proposed change.**
  - `global_value`: read `state.globals[slot]`; enter the name-based path only when that value
    is a `variable_pointer`, which happens only for ink's `ref` parameters.
  - `assign_global`: write through the slot. Only a stored pointer needs the existing
    follow-the-pointer logic.
  - Both must keep the lookahead undo log (`set_global`).
- **Success criterion.**
  - Same hook as F1: 0 `global_slot` calls when playing a story that only reads and writes
    globals.
  - A unit test that a global holding a variable pointer still resolves through ink's rules.
  - Ground truth unchanged.

### F3: the hot-path lint guards the wrong file

- **Evidence.**
  - `hot_path_file = "src/runtime/vm.zig"`, and the forbidden list is `mem.eql`, `hash`,
    `resolve_path`, `path_string` (`tools/lint.zig:45-46`).
  - The step reaches `ops.zig`, `native.zig`, `call_stack.zig`, `lists.zig` and `output.zig`,
    none of which are checked.
  - `benchmarks.md:247` reports the gate as "met".
- **Why it matters.** The gate is how inkz keeps D3/D4's promises honest. A text match on one
  file let F1 and F2 in.
- **Proposed change.**
  - Make `hot_path` a list of files.
  - Add `strings.find`, `_by_name(` and `global_slot(` to the forbidden list.
  - Mark the legitimate non-play users (load, API, `story_paths`) with
    `// lint: allow hot_path: <reason>`, so each exception is explicit.
- **Success criterion.** A lint sample test (like `lint.zig:908`) where `strings.find` inside
  `src/runtime/ops.zig` is reported. `zig build lint` is clean after F1 and F2.

### F4: `Story.init` makes two allocations, not one

- **Evidence.**
  - `story.zig:198` allocates `bindings: []Binding` (one per external) before the state's
    single allocation.
  - The docs promise exactly one: `Guidelines.md:16`, `RunningYourInk.md:571`,
    `benchmarks.md:33`, `ArchitectureAndDevOverview.md:138`.
  - The existing test (`state.zig:792`) covers `State`, not `Story`.
- **Proposed change.**
  - Add the bindings to the budget: `program.externals.len * @sizeOf(Binding)` in
    `bytes_total(shape)`, carved by the `Carver`.
  - If that complicates `Limits`, fix the four docs instead.
- **Success criterion.** A unit test wraps `Story.init` in a counting allocator and expects
  exactly one allocation, of `bytes_total(shape)` bytes, for a program with externals.

### F5: compiler diagnostics are not exposed

- **Evidence.**
  - `compile_parsed` returns `CompileFailed` on any error (`compile.zig:47-50`).
  - `RunningYourInk.md:640` says diagnostics are not available through the API yet.
  - Parse diagnostics are already 12 B structured records (`core.zig:23-39`), and the resolve
    and builder ones are structured too.
- **Why it matters.** Writers can't see why a story failed to compile, and plan §4.11 promised
  `Result{program, diagnostics}`. zirp's flat `errors` array shows this costs nothing on the
  success path.
- **Proposed change.** `compile_source_with(gpa, src, .{ .diagnostics = sink })`, with the same
  sink pattern as tags: `sink.diagnostic(code, severity, file, line, column, message)`. The
  message is rendered on demand. The current `compile_source` signature stays.
- **Success criterion.** A unit test compiles a source with an unknown divert target and an
  unclosed `{`, and checks that the sink receives both, with the right codes and the lines and
  columns inklecate reports for them (harness ground truth).

### F6: source positions are O(offset)

- **Evidence.**
  - `line_and_column` counts every `\n` before the offset on each call (`lexical.zig:82-89`).
  - `Space.location` finds the file by a linear scan (`source_space.zig:76-87`).
  - Plan §4.11 called for a line-start table.
- **Why it matters.** It is cheap today, because a compile stops at the first errors and
  diagnostics are capped at 256. F5 changes that: a host listing every warning in a 16 MiB
  story would pay O(n) per diagnostic.
- **Proposed change.**
  - Build `line_starts: []u32` per file once, lazily on the first diagnostic, and binary-search
    it.
  - Find the file by binary search on `File.start`, which is already sorted.
  - Columns stay relative to the comment-stripped text, as ink's own `CommentEliminator`
    leaves them.
- **Success criterion.** A unit test compares table lookups against `line_and_column` for every
  offset of a multi-file space, and checks that building the table takes one allocation.

### F7: sema reads children by magic position

- **Evidence.**
  - `ast.shape(tag)` gives `fixed(n)`, and consumers index `first + k` directly; a choice is
    `fixed(6)` (`ast.zig:171-205`).
  - zirp's typed views (T6) were planned and dropped in the P13 code cut.
- **Why it matters.** A layout change, such as adding a choice slot, silently shifts every
  reader. zirp gets compile errors in that case.
- **Proposed change.** A cheaper middle ground than full views: one small `enum(u3)` of slot
  names per fixed tag, e.g. `pub const ChoiceSlot = enum(u3) { header, conditions, start,
  option, inner, diverts }`, plus `child(node, comptime slot)`. A comptime assert ties the
  enum's field count to `shape(tag).fixed`.
- **Success criterion.** A comptime test asserts that every fixed tag has a slot enum whose
  length equals its arity. The parser shape tests (`parser_shape_tests.zig`) pass, now reading
  children by name.

### F8: the token layout docs are stale

- **Evidence.**
  - `Architecture.md:113` shows `tokens on demand {tag, start, end}`.
  - `benchmarks.md:249` lists "`Token` 9 B SoA" as a met size guard.
  - The code has `token_starts`/`token_ends` only (`core.zig:52-53`), 8 B, with no guard.
- **Proposed change.** Fix both docs, and the T2 row in the plan, to `{start, end}` 8 B with no
  tag, and add the guard from F10.
- **Success criterion.** A test asserts the workspace's per-token bytes are 8, and the doc text
  says the same.

### F9: Guidelines describe labeled switches that don't exist

- **Evidence.**
  - `Guidelines.md:195-200`: "Scanners are labeled-switch state machines", and VM dispatch
    "currently fits in 70 lines without the exception".
  - There is no `continue :` anywhere in `src/`.
  - The compiler has no scanner: rules read characters.
  - The VM is a `while` + `switch` (`vm.zig:88-346`).
- **Proposed change.**
  - Keep the rule for future scanners.
  - State that the grammar is scannerless (ink is context-sensitive), and that the VM uses a
    plain switch because P12.3 showed dispatch is not the bottleneck.
  - Either drop the unused D10 `function_length` exception or note that it is reserved.
- **Success criterion.** The doctest for the sample block still passes, and no doc claims a
  labeled-switch VM or tokenizer.

### F10: missing size guards

- **Evidence.** These have no `@sizeOf` assert:
  - parser `Frame` (~36 B) and `Checkpoint` (5 × `u32`) (`core.zig:164-181`);
  - the compiler `Diagnostic` (12 B, `core.zig:23-39`);
  - the IR `Stored` union, "at most 24 B" in a comment (`lower_ir.zig:~114-135`);
  - sema's per-object bytes.

  Guidelines require size assertions, and fino's T14 was adopted for runtime types only.
- **Proposed change.** Comptime asserts next to each type, plus rows in `sizes_test.zig`, using
  `soa_bytes` for the SoA tree.
- **Success criterion.** The new rows in `sizes_test.zig` fail if any of these types grows.

### F11: "no pointers in persistent data" is unenforced

- **Evidence.**
  - Guidelines §"Index newtypes, no pointers in persistent data" says copying with `@memcpy`
    (snapshots, parking) relies on there being no pointers.
  - `State` holds `program: *const Program`; `Observer` holds `callback`/`context`; `Borrowed`
    stamps hold `*const u32`. These are all fine because none of them is snapshotted.
  - Nothing *checks* that the element types that are snapshotted are pointer-free. Today only
    alignment and 4 B multiples are asserted (`state.zig:~185-196`).
- **Proposed change.**
  - Add a comptime `has_no_pointers(T)`, the sibling of `has_no_allocator`, applied to every
    `FlowBuffers` element, `PatchEntry`, `Value` and `Choice`.
  - Narrow the Guidelines wording to "data that is copied, parked, saved or snapshotted".
- **Success criterion.** A comptime test fails if a pointer field is added to any of those
  types.

### F12: `intern` hashes twice

- **Evidence.** `intern` calls `find` (one hash), then `putAssumeCapacityNoClobberContext`,
  which hashes again (`string_pool.zig:110-124`).
- **Proposed change.** `getOrPutContextAdapted(bytes, BytesAdapter, ...)`. On a new entry, append
  the bytes and set the key to the new id, all with one hash.
- **Success criterion.** A unit test with a counting hash context checks that one new `intern`
  hashes once, and that one repeated `intern` hashes once and doesn't grow the pool.

### F13: resolve hashes names as strings

- **Evidence.** The scoped tables use the key `{scope: ObjectIndex, name: []const u8}` with
  Wyhash over the bytes (`resolve.zig:176-193`). Names are interned only when the builder runs.
- **Proposed change.** Intern names into a compile-local pool when sema builds objects, so keys
  are 8 B integers. Freeze that pool into the Program's, so the builder doesn't intern again.
- **Success criterion.** Resolve's key type is `{ObjectIndex, StringId}`, with a size assert of
  8. The compile benchmark shows no regression; record the before and after.

### F14: a workspace overflow costs a full re-parse

- **Evidence.**
  - `WorkspaceFull` re-parses at `scale*2`, up to 3 retries (`grammar.zig:~566-597`).
  - Benchmark lead 1 measured this at 32% of a large compile before P12.2 retuned the estimate.
- **Proposed change.** Keep the design (T15), and protect the estimate instead.
- **Success criterion.** A test compiles every story in the e2e corpus and asserts zero
  retries, so a regression in the estimate shows up as a test failure, not as a slowdown.

### F15: native ops dispatch at run time

- **Evidence.**
  - `native.binary(context, opcode, a, b)` switches on the common type, then on the opcode
    (`native.zig:100-121`).
  - fino monomorphises with `inline .add, .sub, … => |op|` and a `comptime op`.
- **Why low.** P12.3 showed play time is spent in the step bodies, not in dispatch, so this
  might buy little.
- **Proposed change.** Benchmark first, with `bench-profile` zones around `call_native`. Change
  only if the zone is more than ~5% of play.
- **Success criterion.** A recorded bench-profile entry in `benchmarks.md` either way.

### F16: the plan doesn't say what was built

- **Evidence.** `DODMigrationPlan.md` is "accepted, revision 4" and describes what was intended:
  - a labeled-switch lexer and VM (§1 items 1 and 5, T2, T12);
  - list bitsets (§4.4);
  - a line table and `Result` (§4.11);
  - `named_count: u16`;
  - SoA small tables.

  The code differs on every one, for documented reasons.
- **Proposed change.** Add an "As built" column to the T1–T19 table, as §18 of this document
  does, and a short "deviations" list under §1.
- **Success criterion.** Every T-row has a status, and no section describes something as done
  that the code doesn't do.

### F17: no trusted image load

- **Evidence.**
  - `program_image` load always validates: opcode table, layouts, `decodable` extra words.
    `program_check` is 20–23% of an image load.
  - `benchmarks.md:439-442` proposes a trusted entry point that was never built.
- **Why low.** Loading is already 18–20× faster than JSON, and validation is the safety net for
  untrusted files.
- **Proposed change.** Add it only if a host needs it: `load_trusted(image)`, which skips
  validation but keeps `Program.verify()` in safe builds.
- **Success criterion.** A test loads the same image both ways and gets equal Programs; a fuzz
  target keeps covering only the validating path.

### F18: save load runs twice

- **Evidence.** `load.zig` validates in one pass and commits in a second. Benchmark lead 8 puts
  each at about 45%.
- **Why low.** The two passes are what make a failed load leave the story untouched (D15).
  Saves are loaded rarely.
- **Proposed change.** None for now. If it matters, validate into the lookahead buffers, which
  are idle during a load, and swap them in.
- **Success criterion.** If changed: the existing "failed load leaves the story unchanged" tests
  still pass.

### Checked and left as is

These comparisons looked like gaps, but they hold up:

- **Plain-switch VM instead of fino's threaded dispatch.** Measured not to matter (P12.3, 0–2%).
  Only the docs need fixing (F9).
- **Ordered list arrays instead of bitsets.** ink's `LIST_RANDOM` and tie-breaking need
  insertion order, and lists are small.
- **No `TagSet`.** There are no token tags; rules stop on characters.
- **Mark-compact instead of refcount/COW (D4).** The lookahead truncation depends on an
  order-preserving heap.
- **`missing` nodes hold an offset, not a diagnostic index.** That avoids zirp's out-of-range
  index when its error list overflows.
- **`parsing_choice` is not restored on backtrack.** This matches C# exactly: `_parsingChoice`
  is set and cleared with no early return in between (`InkParser_Choices.cs:39-79`).
- **The evaluation stack is shared across flows.** That matches C#, where `evaluationStack`
  lives in `StoryState`, not in `Flow`.
- **The IR is AoS with a linked list per container.** It is short-lived and flattened before
  emission, and the stages before it are freed early.
- **Physical `none` slots for optional children.** They keep `fixed(n)` arities and make
  backtracking a truncation. zirp's per-tag layouts (`BranchNodeComplex`) would save bytes on
  choices, but the AST is freed before lowering, so the bytes don't matter.

Conversely, inkz is stronger than both references on bounded recursion, allocation
discipline, untrusted-input validation and invariant checking in shipping builds. Those are
the properties a library embedded in a game needs, and a research parser or a toy VM can
skip them.
