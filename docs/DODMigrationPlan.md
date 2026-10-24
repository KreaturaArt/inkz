# DOD Migration Plan — full data-oriented inkz (TigerStyle edition)

Status: accepted, revision 3 (2026-10-24). All decisions D1–D16 confirmed. Sources: audits of `src/runtime` and `src/compiler`, plus the reference projects `reference/fino` and `reference/zirp`. Engineering rules come from `TIGER_STYLE.md` (repo root).

Revision 2 changes: TigerStyle is now a first-class constraint. That brought a new section §3 ("Engineering rules"), renamed identifiers (snake_case files, no abbreviations), no recursion anywhere, explicit limits, assertion density and paired verification, function and line limits, Zig-only tooling, fuzzing and simulation, and new decisions D8–D11.

Revision 3 changes: gap review. Decided D12–D16:
- line-based `cont()` with newline lookahead
- ink C# semantics as ground truth
- i32/f32 scalars, so `Value` is 12 B
- bidirectional save compatibility with C# ink
- compiler migration that retargets codegen first

Other additions:
- New §4.6 (Continue semantics), §4.7 (host contract), §4.10 (save format).
- Fixed `evaluate_function` semantics.
- Visit counting on divert.
- Choice thread snapshots.
- Flow storage.
- Compaction at any safepoint.
- A total memory budget.
- .NET `System.Random`.
- Errors and warnings.
- Support for ink.json v20.
- Tokens store their `end`.
- INCLUDE source space.
- A divergence ledger.
- An engine-neutral test layer.
- A parser spike.
- Dependency graph fixes.

---

## 0. Executive summary

inkz today is "index-based" but not data-oriented.

**Runtime problems:**
- It walks a tree of `Container`s holding 40-byte `RuntimeObject` unions that serve as both instruction and value.
- Divert, choice and read-count targets are path strings, re-resolved on every execution (`story.zig` `resolvePath` splits the path, calls `parseInt`, and does a linear strcmp `namedLookup`).
- Variables are `StringHashMap` lookups that walk every frame. `CallStack.push` allocates a hashmap for each call.
- The hot path allocates into one arena that is never reclaimed.
- Weave heuristics (`loopBackGatherTailPeel`, `divertTargetsAncestorOfAnyChoiceSource`) run every step while choices are pending, and some of them recurse.
- Functions run to hundreds of lines.

On top of that, several behaviours **diverge from ink** (§1.1), so the old runtime cannot be the ground truth.

**Compiler problems:**
- The tokenizer emits coarse `text` tokens, which are re-lexed as strings in a second `ExprParser`.
- It builds two recursive pointer trees (`Parsed.*` with 40–104 B nodes, then `CObject`/`CContainer`).
- Paths are strings (62 `allocPrint`s) and opcodes are strings.
- The symbol table is global and unscoped.
- It produces no usable diagnostics.

**Target design** (zirp for the front end, fino for the IR/VM, TigerStyle for the engineering rules):

1. **Tokens.** SoA `{tag: u8, start: u32, end: u32}` produced by one mode-aware labeled-switch lexer.
2. **AST.** SoA `{tag: u8, payload: u32}`, 5 bytes per node, children stored contiguously. It is built by a **non-recursive**, explicit-stack parser with resilient grammar (`.missing` nodes and an error array).
3. **Program** ("story image"). One immutable, interned, pre-resolved bytecode image, **shared by the compiler output and the JSON loader**, and shareable between many `Story` instances. It contains:
   - SoA instructions `{opcode: u8, operand: u32}` plus an `extra: []u32` side table. i32 and f32 literals live directly in the operand.
   - the string pool
   - the container table
   - the list item table
   - the global table
4. **Runtime state.** Every buffer is **statically allocated at init** with explicit limits, checked overflow and a computed total byte budget:
   - a flat frame array (threads are ranges into it)
   - a flat temp array
   - a compact output stream
   - a 12-byte `Value`
   - a fixed-size string/list heap that is sliding-compacted at any safepoint
   - a lookahead snapshot with a change log
   - choice thread snapshots
   - parked flows

   `cont()` returns one line, as ink's `Continue()` does, and performs zero allocations; a test enforces this.
5. **Dispatch.** A labeled-switch threaded interpreter in a standalone hot-loop function with primitive/slice arguments, using `inline` prongs and `comptime opcode` for native ops.
6. **Safety.** Every function averages at least 2 assertions. `Program.verify()` and `State.verify()` are pair-checked (after build and after load; before save and after load). Compile-time size and relationship asserts. Fuzzing plus a deterministic story simulator.

**Ground truth is ink's C# behaviour** (D13). Expected results come from:
- ink's own runtime test suite (harvested in P0.10)
- inline assertions in our tests
- inklecate-compiled fixtures

The old runtime is used as a **differential oracle**, with a **divergence ledger** listing every known difference and its reason (P0.4).

**Migration** uses a strangler pattern. The new Program and VM are built alongside the old code and gated by the oracle and the ground-truth suite. Old code is deleted at the end. The baseline stays green on every merge, except for tests explicitly moved to the ledger. "Zero technical debt" applies to new code from the first commit; old code is exempt only until it is deleted.

---

## 1. Baseline facts (measured 2026-10-23)

- `zig build test` with **Zig 0.16.0** passes 549/549.
- With the default **Zig 0.17.0** the build fails because `Allocator.dupeZ` is gone (`parser.zig:25`, `tokenizer.zig:359` ×2). The replacement is `dupeSentinel`.
- Tests:
  - about 220 runtime unit tests, 199 of them in `story.zig`. Most reach into internal fields.
  - 51 parser shape tests
  - 28 tokenizer tests
  - 209 compiler e2e tests (output-text based, `compiler_helpers.zig`)
  - 11 runtime fixture tests
  - about 14 codegen/serializer/c2r/parity tests
- Fixtures:
  - 169 `.ink` sources and 171 compiled `.json`
  - 166 compiled files are `inkVersion` 21 and 5 are `inkVersion` 20
  - **no expected-output files**. Correct answers exist only as inline test assertions.
- Type sizes:

| Type | Size |
|---|---|
| `RuntimeObject` | 40 B |
| `Container` | 72 B |
| `Story` | 4632 B, returned by value from `initFromJson`, which TigerStyle forbids for large structs |
| `Choice` | 72 B |
| `Element` | 48 B plus an owned hashmap |
| `FlowItem` | 104 B |
| `InlineElement` | 80 B |
| compiler `Token` | 16 B |

- TigerStyle violations in the current code:
  - recursion in the parser, codegen, c2r, weave heuristics and JSON writer
  - many functions over 70 lines (for example `dispatchObject`, `runStepLoop`, `loadStateFromJson`, `parseContent`)
  - `usize` everywhere
  - unchecked `appendAssumeCapacity` limits
  - few assertions
  - camelCase functions
  - file names are already snake_case, as the rule requires

### 1.1 Semantic divergences of the old runtime from ink (verified in code)

| # | Old behaviour | Ink behaviour |
|---|---|---|
| S1 | `evaluateFunction` saves the state as JSON and restores it afterwards (`story.zig` ~555), **discarding all side effects** | Runs on the live state in a `FunctionEvaluationFromGame` frame; only the produced output is trimmed, and all other side effects persist |
| S2 | `cont()` runs to the next choice or end (ink's `ContinueMaximally`) | `Continue()` returns **one line**, with that line's tags, using newline lookahead |
| S3 | `recordVisitIfNeeded` counts only the divert target | Every container newly entered between the common ancestor and the target is counted; `count_start_only` is honoured |
| S4 | `count_at_start_only` is parsed but never used | Containers with this flag count only when entered at index 0 |
| S5 | A choice made inside a thread loses its thread (test note "not yet implemented") | Each choice stores `threadAtGeneration`, a copy of its thread's call stack |
| S6 | Observers fire immediately, at each assignment | Notifications are batched per `Continue()` |
| S7 | `RANDOM`/`SEED_RANDOM` don't use .NET `System.Random`, and `story_seed` never advances | All randomness uses .NET `System.Random` semantics; `storySeed` and `previousRandom` are state |
| S8 | `Value.int` is i64 and floats are f64 | C# `int` (32-bit, wrapping) and `float` (32-bit) |
| S9 | Saves miss choices, flows, tags, the seed and divert values | Save format v10 with `flows`, `choiceThreads`, `previousRandom` and more |

The old runtime's results for any of these are **not** reference behaviour. Each row is an entry in the divergence ledger (P0.4) and has a dedicated phase item that fixes it.

---

## 2. Techniques adopted from the references

| # | Technique | Source | Applied in inkz |
|---|---|---|---|
| T1 | `enum(u32) { none = maxInt, _ }` index newtypes | fino `index_sea/Parser.zig:9`, zirp `Ast.zig:55` | `ContainerIndex`, `InstructionIndex`, `StringId`, `NodeIndex`, `TokenIndex`, `GlobalSlot`, `ListItemIndex`, `ListOriginIndex`, `ExternalIndex`, `FlowIndex`, `FileIndex` |
| T2 | Token = `tag` u8 + `start` u32 in separate arrays | zirp `Tokenizer.zig:65-110` | compiler tokens. **Deviation:** we also store `end` u32 (9 B per token). Ink lexing is context-sensitive (for example inside a choice's `[...]`), so recovering the end by re-lexing from a hint is a source of subtle bugs. |
| T3 | Node = `tag` u8 + packed-union u32 (`first_child` / `token` / `none` / `missing`); children contiguous; lists trailing | zirp `Ast.zig:37-53` | compiler AST |
| T4 | Scratch stack `marker`/`push`/`push_up`/`wrap`; nodes are append-only, so backtracking only truncates counts | zirp `Parser.zig:386-445` | parser |
| T5 | Grammar never fails: `expect` returns `.missing` plus an error; `skip` recovers; a gas counter (= TigerStyle loop bound); first-set invariant | zirp `grammar.zig` | parser |
| T6 | Comptime typed views plus `to_typed()`; comptime exhaustiveness checks (= TigerStyle compile-time asserts) | zirp `Ast.zig:2267-2660` | AST API, sema |
| T7 | `TagSet` comptime bitsets | zirp `Ast.zig:813` | parser first/recovery sets |
| T8 | `string_bytes` plus an adapted `HashMapUnmanaged(u32, void, Context)`; deduplicate by tentative append and shrink | ZIR `AstGen.zig:11011` | `string_pool.zig` |
| T9 | `extra_add` / `extra_get(T, index) -> {data, end}` serialization into `extra: []u32` | ZIR `AstGen.zig:72` | wide operands |
| T10 | Shared instruction buffer with `instructions_top` for nested bodies | ZIR GenZir | lowering of nested containers |
| T11 | Fixed instruction: `opcode` u8 + u32 operand; packed sub-payloads via `@bitCast` | fino `Vm.zig:229` | `Instruction` |
| T12 | Labeled-switch threaded dispatch, `pc` kept in a local, `inline` prongs plus `comptime opcode` | fino `Vm.zig:400-849` | `vm.zig` |
| T13 | Comptime-typed constructors `instruction_add(comptime opcode, @FieldType(...))` | fino `moar_smaller/Parser.zig:385` | program builder |
| T14 | `@sizeOf` guard tests | fino | every core type (TigerStyle "assert type sizes") |
| T15 | Reserve up front, flag overflow, retry with doubled capacity, then copy an exact-size result | zirp `Parser.reserve` | compiler workspace (init-phase only) |
| T16 | Side tables keyed by `NodeIndex` | zirp `AstRlAnnotate`, `Render.Fixups` | sema results |
| T17 | Refcount and copy-on-write | fino `Vm.zig:37-79` | **rejected**, see D4 |
| T18 | Snapshot tests (`.ast.zon`, `SNAP_UPDATE=1`), correctness and resilience corpora, `// error` markers | zirp `main.zig:245-480` | parser tests |
| T19 | Post-order and marker linearisation with backpatch stacks, compiled in **one non-recursive pass** | fino `moar_smaller/compiler.zig` | sema and lowering traversal (D9) |

**Rejected:**
- From fino: per-push `try append`, per-call `call_stack` allocation, re-duplicating literals on every execution, and the refcount/COW scheme.
- From zirp: the recursive grammar functions (we keep the node layout and recovery model but drive them from an explicit stack, D9), and token-end recovery by re-lexing (T2 deviation).

---

## 3. Engineering rules (TigerStyle, applied to inkz)

These rules apply to **all new code** and are checked in review and by tooling (P0.8). Each rule says how it is enforced.

### 3.1 Safety

| Rule | inkz application | Enforcement |
|---|---|---|
| **No recursion** | Parser, sema, lowering, JSON loader/writer, save/load, list display, path printing, path resolution and the heap compactor all use explicit bounded work stacks, or rely on post-order layouts that need no stack. The VM is a flat loop; calls push frames onto a `BoundedStack`, never onto the native stack. | Lint: call-graph cycle check over `src/` (P0.8). It is name-based: `std.zig.Ast` cannot resolve method calls through types, so it over-approximates, and any false positive needs an explicit suppression comment with a reason. |
| **A limit on everything** | `src/core/limits.zig` holds comptime defaults, overridable at runtime through `Story.Options.limits` and `Compiler.Options.limits`. Bounds include: frames, threads, temps, eval stack, output items, output bytes, choices, tags, heap bytes, list slab words, flows, parked-flow bytes, choice-snapshot frames, lookahead patch entries, observers, errors/warnings, steps per `cont()`, parser nesting depth, diagnostics, tokens/nodes per byte of source, include depth and file count. Every loop has a bound or an assertion that it terminates. | Overflow returns a named error (`error.FrameLimit`, …); tests for each limit |
| **A total memory budget** | `Limits.bytes_total()` computes the exact bytes `Story.init` will allocate. | A test pins the default budget, and a test asserts that the init allocation equals `bytes_total()` |
| **Explicitly sized types** | `u32` indices and counts everywhere. `usize` only appears at slice-indexing boundaries, through `@as(usize, index)`. | Lint: `usize` in a struct field is an error |
| **≥ 2 assertions per function** | Preconditions on arguments, postconditions on results, invariants. Split compound asserts. Use `if (a) assert(b)` for implications. Assert both the positive and the negative space. | Lint: per-file assertion density report; review |
| **Pair assertions** | `Program.verify()` runs after `ProgramBuilder.finish()` (compiler path) and after JSON load (loader path). `State.verify()` runs before `to_json` and after `load_json`, and in Debug after every `cont()`. The heap compactor verifies before and after compaction. Serialization is checked by `load(serialize(p))` equal to `p`. | Tests call verify; Debug builds call verify at the boundaries |
| **Compile-time relationship asserts** | `comptime assert(@sizeOf(Value) == 12)`; `Opcode` fits u8; limits fit their index types (`frames_max <= maxInt(u24)` where packed); `ListItemIndex` count fits the bitset words. | Compile-time |
| **Static allocation** | Runtime: everything is allocated in `Story.init`, and nothing after it, including during `load_json` (D4, P5.7). Compiler: allocation happens only in its init/compile phase, from an arena sized from the source length, with a bounded retry (T15). | Counting-allocator test gate |
| **Smallest scope, no aliases or duplicated state** | For example, the VM keeps `pc` and `container_index` in locals and writes them back to the frame only on call, return or yield. There is no cached copy elsewhere. | Review |
| **≤ 70 lines per function** | Push `if`s up and `for`s down. Parents own control flow and helpers stay pure. Exactly two documented exceptions: the `vm.run` dispatch switch and the tokenizer's labeled-switch state machine (D10). | Lint (P0.8) |
| **Strictest warnings, all errors handled** | No `catch unreachable` on operating errors and no `_ = try`-swallowing. Every error set is explicit on public functions. | Lint + review |
| **Explicit options at call sites** | `std.mem.sort(…, .{…})`, explicit `std.json` options, and so on. | Review |
| **Simple control flow** | Split compound conditions into nested `if`/`else`. State invariants positively (`index < count`). | Review |
| **Don't react directly to external events** | Variable observers are **queued** during one `cont()` call and dispatched in a batch at its end, as ink's `batchObservingVariableChanges` does. External functions are called synchronously only at their defined instruction. Callbacks receive values, never pointers into state, under the lifetime contract in §4.7. | Test: an observer fires once per `cont()` per variable, after output |

### 3.2 Performance

- **Back-of-envelope sketch per phase.** Every phase task starts with a short sketch of memory bytes and cache lines touched per op (for example: an instruction is 5 B, so 64 B holds about 12 instructions; a `Value` is 12 B; a frame is ≤ 24 B). The sketch is recorded in the task's implementation notes before any code is written.
- **Control plane vs data plane.** Loading, verification, save/load and the compiler are the control plane, and assertions there are heavy. `vm.run()` is the data plane: assertions use `std.debug.assert`, which compiles out in ReleaseFast but stays in ReleaseSafe, and the verify passes run at batch boundaries (`cont()` calls), not per instruction.
- **Batching.** The unit of work is one `cont()` call, which produces one line (D12). Output text is assembled once per call and observers are dispatched once per call. The heap is compacted lazily, only when an allocation fails (§4.5).
- **Hot loops as standalone functions.** `vm.run()` takes primitive arguments and slices (`opcodes: []const Opcode`, `operands: []const u32`, `state: *State`), not `self: *Story`.
- **Performance targets are measured in both ReleaseFast and ReleaseSafe.** Acceptance targets (§9) apply to ReleaseSafe, because that is the shipped default (D11).

### 3.3 Developer experience

- **Naming.**
  - snake_case for files, functions and variables. This changes the public API too (D8).
  - No abbreviations: `container_index` not `cidx`, `instruction` not `inst`, `string_id` not `str_id`, `source`/`target` not `src`/`dest`.
  - Units and qualifiers come last: `frames_max`, `frames_count`, `heap_bytes_max`, `steps_max_per_turn`.
  - Keep **index**, **count** and **size** distinct in every name.
  - Proper acronym capitalisation: `JSONLoader`, `VMState`.
  - Related names have equal length where possible (`source_offset`/`target_offset`).
- **Struct ordering.** Fields, then types, then methods. Complex nested types move to top level.
- **Large structs.** Anything over 16 B is passed as `*const`. `Story`, `State` and `Program` are initialised in place through an out-pointer (`story.init(gpa, program, options)`).
- **Options structs.** Any function with two same-typed arguments takes an `options` struct.
- **Comments.** Full sentences that say *why*. Every test begins with a comment giving its goal and method.
- **Layout.** `zig fmt`, 4 spaces, at most 100 columns, braces on every multi-line `if`.
- **Zero dependencies, Zig-only tooling.** Transcript generator, lint, bench, fixture runner and snapshot updater all live in `tools/*.zig` (no shell or Python), wired as build steps.

---

## 4. Target architecture

### 4.1 Shared core (`src/core/`)

- `index.zig`: the T1 newtypes. Each has `.none`, `from_int` and `to_int`; `to_int` asserts `!= .none`.
- `limits.zig`: comptime defaults plus the `Limits` struct, with relationship asserts and `bytes_total()`.
- `string_pool.zig` (T8):
  - storage is `bytes` (NUL-terminated entries; id 0 is `""`) plus an adapted table
  - API: `intern`, `get`, `find` (no insert), and `freeze() -> FrozenStringPool`
  - asserts that `get` is only called with ids it issued
- `extra.zig` (T9): `extra_add`, `extra_get`, `extra_reserve`, `extra_set`.
- `bounded_stack.zig`: a `BoundedStack(T)` over a fixed slice, with `push() error{…}!void`, `pop`, `peek`, `truncate(mark)` and `verify()`. It replaces every unchecked `appendAssumeCapacity`.
- `tag_set.zig` (T7).
- `work_stack.zig`: a bounded explicit stack used as the replacement for recursion in traversals. Pushing past the limit is an operating error, never undefined behaviour.
- `dotnet_random.zig`: a bit-exact port of .NET `System.Random` (the Knuth subtractive generator), used for `RANDOM`, `SEED_RANDOM` and shuffle sequences (S7).
- `path.zig`: a non-allocating parser and resolver for ink path strings (named, numeric and `^` components, relative and absolute). It is control-plane only, used by `choose_path_string`, `visit_count_at_path_string`, save/load (divert-target values, `cPath`) and the loader.

### 4.2 Program (immutable story image), `src/core/program.zig`

```zig
pub const Program = struct {
    strings: FrozenStringPool,
    instructions: std.MultiArrayList(Instruction).Slice, // opcode[], operand[]
    extra: []const u32,
    containers: std.MultiArrayList(ContainerInfo).Slice,
    named: []const NamedEntry,      // {name: StringId, container: ContainerIndex}, per container
    globals: std.MultiArrayList(GlobalInfo).Slice,
    list_origins: std.MultiArrayList(ListOrigin).Slice,
    list_items: std.MultiArrayList(ListItem).Slice,
    externals: []const ExternalInfo, // name, argument_count, fallback ContainerIndex
    root: ContainerIndex,
    ink_version: u32,                // 20 or 21, as loaded

    pub fn verify(program: *const Program) void { ... } // pair assertion, see §3.1
};

pub const Instruction = struct { opcode: Opcode, operand: u32 }; // SoA: 5 B each
comptime { assert(@sizeOf(Opcode) == 1); }

pub const ContainerInfo = struct {
    instruction_first: InstructionIndex,
    instruction_count: u32,
    parent: ContainerIndex,
    index_in_parent: u32,         // maxInt(u32) for named-only children (knots, stitches)
    depth: u16,                   // root = 0; used for the common-ancestor walk (§4.6)
    name: StringId,               // .none if anonymous
    path: StringId,               // dotted path, used for save/load and choice ids
    path_hash: u32,               // precomputed ink shuffle seed (sum of path chars)
    named_first: u32,
    named_count: u16,
    flags: ContainerFlags,        // visits / turns / count_start_only
    count_slot: u32,              // dense index into visit/turn arrays, or none
};
```

- **Opcode set.** `Opcode` is a single `enum(u8)` that merges `ControlCommand`, `NativeFunction` and the structural ops:
  - literals and output: `text`, `integer`, `float`, `bool`, `void`, `glue`, `newline`
  - flow: `enter_container`, `divert`, `divert_conditional`, `divert_variable`, `call_function`, `call_tunnel`, `call_external`, `start_thread`, `choice_point`
  - variables: `global_get`, `temp_get`, `global_set`, `temp_set`, `variable_pointer`
  - counts and targets: `read_count`, `divert_target`
  - lists: `list_literal`
  - all control and native ops
- **Scalars are inline.** `integer` carries an i32 and `float` an f32, bit-cast into the operand (D14). There are no constant pools.
- **Targets are resolved before execution.** Operands are a `ContainerIndex`, or a `{container, index}` pair stored in `extra`. The hot path never sees a path string. `Program.verify()` asserts that every target operand is in range.
- **Newlines** have their own opcode and output-item kind, so the hot path does no `mem.eql` on `"\n"`.
- **One instruction array.** All container contents are stored contiguously; a nested container appears as `enter_container index` at its position in the parent.
- **Immutable and shareable.** Many `Story` instances, possibly on different threads, may share one `*const Program`. Bindings (externals, observers) and all mutable data live in `Story`/`State`.

### 4.3 Value (12 B, compile-time asserted)

```zig
pub const Value = union(enum(u8)) {
    null, integer: i32, float: f32, bool: bool,
    string: StringReference,       // u32; the high bit selects the program pool or the state heap
    divert_target: ContainerIndex, // plus an instruction index via extra when needed
    variable_pointer: VariablePointer, // { name: StringId, context: i32 }; -1 unknown, 0 global, n = frame
    list: ListReference,           // index into the state list slab
};
comptime { assert(@sizeOf(Value) == 12); }
```

- **Integer arithmetic** wraps as C# does (`+%`, `-%`, `*%`). Division and modulo check for zero and for `minInt / -1` explicitly. Float formatting reproduces C#'s `float.ToString(CultureInfo.InvariantCulture)` (D14).
- **`variable_pointer`** needs the full 8-byte payload: a name plus a call-stack context index, as in ink's `VariablePointerValue.contextIndex`. Global pointers are resolved to their `GlobalSlot` at use time.

### 4.4 Lists

- Each list item gets a global dense `ListItemIndex`. A list value is a fixed-width bitset in the state list slab: `div_ceil(list_items_count, 64)` words, plus an origin bitset.
- Set ops (union, intersect, difference, contains, equality, invert, all) are word-wise. Min, max and count use `@ctz`, `@clz` and `@popCount`.
- Display order comes from a precomputed `(origin, value)` table. Nothing is sorted at runtime and no strings are built.

### 4.5 Runtime state (`src/runtime/state.zig`)

Every buffer is sized from `Limits` once, in `Story.init`. Nothing grows after that. Their sum is `Limits.bytes_total()`.

```zig
// Live flow (the "working set").
evaluation:   BoundedStack(Value),
frames:       BoundedStack(Frame),        // every thread's frames, flat
threads:      BoundedStack(ThreadInfo),   // {frame_first, frame_count, index, pointer_previous}
temps:        BoundedStack(Temp),         // {name: StringId, value: Value}
output:       BoundedStack(OutputItem),   // {kind: u8, a: u32, b: u32}
string_marks: BoundedStack(u32),          // begin_string positions, so end_string is O(1)
choices:      bounded MultiArrayList(ChoiceRecord), // incl. snapshot range, tag range
choice_snapshots: ChoiceSnapshotArea,     // thread copies per choice (below)
// Shared across flows.
globals:      []Value,                    // indexed by GlobalSlot
visit_counts: []u32, turn_indices: []i32, // indexed by count_slot
turn_index:   i32,
story_seed:   i32, previous_random: i32,  // S7
heap:         StateHeap,                  // fixed bytes for strings + fixed list slab
// Control plane.
lookahead:    LookaheadSnapshot,          // §4.6
flows:        FlowTable,                  // names + parked flows (below)
observer_queue: BoundedStack(GlobalSlot), // batched, see §3.1
errors:       BoundedStack(Diagnostic),   // ink currentErrors
warnings:     BoundedStack(Diagnostic),   // ink currentWarnings
```

- **Temp lookup** scans the current frame's temps comparing u32 ids. The scan is bounded by `temps_per_frame_max`, which is asserted. This keeps ink's exact semantics.
- **Thread fork** copies the frame and temp ranges with `@memcpy`, with bounds asserted first.
- **Choice thread snapshots (S5).** When a choice is generated, ink stores a copy of the current thread (`threadAtGeneration`). `ChoiceSnapshotArea` is a bounded frame/temp arena:
  - Each choice records a range in it.
  - Consecutive choices generated by the same thread at the same call-stack state share one snapshot, which is the common case in a weave.
  - Choosing a choice restores its snapshot as the current thread.
  - The area is reset whenever the choice list is cleared.
  - Limit: `choice_snapshot_frames_max`.
- **Flows.** Globals, visit counts, turn indices and the RNG state are shared, as in ink. Per-flow data is the call stack, output, choices and choice snapshots.
  - Only the active flow lives in the working-set buffers.
  - `switch_flow` packs the used prefix of each working-set buffer for the outgoing flow into a bounded `flow_parking` byte region with a per-flow directory, then unpacks the incoming flow. That costs a `@memcpy` proportional to used state, not to limits.
  - The parking region is compacted on removal. Limits: `flows_max` and `flow_parking_bytes_max`.
- **StateHeap** has fixed capacity and uses **sliding mark-compact**, which preserves allocation order.
  - Compaction runs **only when an allocation fails**, which can happen at any instruction boundary inside `vm.run`, because a single `cont()` can build arbitrarily many strings.
  - Roots: globals, temps, the evaluation stack, output items, choices (text and tags), choice snapshots, parked flows, the lookahead snapshot and the pending observer queue.
  - Running out of heap after compaction returns `error.HeapLimit`.
  - Debug builds poison the vacated space and call `verify()` before and after compacting. The simulator has a mode that compacts before every allocation.
- **Output** is assembled into a fixed `output_bytes` buffer. `cont()` returns a borrowed slice that is valid until the next mutating call (D5, §4.7).
- **Errors and warnings** mirror ink's `currentErrors`/`currentWarnings` lists, for example "ran out of content" or an unknown variable. A story-level error makes the next public call return `error.StoryError`, unless the host installed an error handler.

### 4.6 Continue semantics (line-based, D12)

`cont()` implements ink's `ContinueInternal`:

1. Clear the previous line's output and tags. Reset the step budget. Begin batching observers.
2. Step the VM. When the output stream ends in a newline and no lookahead snapshot exists, **take a snapshot**:
   - `@memcpy` of the used prefixes of the live-flow stacks into the `LookaheadSnapshot` buffers
   - the heap top mark
   - start the **change log**: a bounded log of the previous values of `globals`, `visit_counts`, `turn_indices`, `turn_index` and the RNG state (ink's `StatePatch`, inverted into an undo log)
3. Keep stepping. Then:
   - If glue removes the newline, or nothing visible follows, discard the snapshot and continue.
   - If new visible content follows, **restore**: copy the stacks back, undo the change log, truncate the heap to the mark, and return the line up to the newline.
4. **External functions** without `lookahead_safe` that are reached while a snapshot is active stop the lookahead. The line ends at the snapshot, and the external function runs on the next `cont()`. This matches ink.
5. **Heap interaction.** Sliding compaction during lookahead treats the snapshot as a root and relocates the heap mark. This is valid because sliding preserves order, so objects allocated before the snapshot stay below the relocated mark.
6. At the end: assemble the line text and tag views, dispatch batched observers, and run `State.verify()` in Debug.

`continue_maximally()` loops `cont()` until `can_continue()` is false, writing into a caller-provided buffer (or `continue_maximally_alloc(gpa)`).

**Visit counting on divert (S3/S4).** On every pointer change that crosses container boundaries (divert, return, choice selection, falling into a container), the VM finds the common ancestor of the old and new container using `depth` and `parent`, then increments the visit counts (and sets the turn indices) of every newly entered container from the ancestor down to the target. A container with `count_start_only` is counted only when it is entered at instruction index 0. `enter_container` is the fast path for the fall-through case.

### 4.7 Host contract (public API surface)

- **Construction.**
  - `story.init(gpa, program: *const Program, options)` borrows the program, which must outlive the story.
  - `story.init_from_json(gpa, json, options)` builds and owns a program.
  - `deinit` frees exactly what `init` allocated.
- **Mutating calls.** These are `cont`, `continue_maximally`, `choose_choice_index`, `choose_path_string`, `set_variable`, `evaluate_function`, `switch_flow`, `remove_flow`, `load_json` and `reset_state`.
- **Lifetimes.** Every borrowed view (line text, tags, choice text, choice tags, variable string values, `current_errors()`) is **valid until the next mutating call**. Debug builds stamp views with a generation counter and assert on stale use.
- **Variables.** `get_variable(name) ?Value`, `set_variable(name, value) !void` (type-checked as in ink; strings are copied into the heap), and `global_variable_names()` iteration. `set_variable` triggers observers immediately, because it happens outside `cont()`, as in ink.
- **Callbacks.** External functions and observers receive `[]const Value` views whose strings are slices. Those slices are valid only during the callback. A string returned by an external function is copied into the heap before the VM resumes. Calling a mutating story method from inside a callback returns `error.Reentrant`.
- **`evaluate_function(name, args, text_writer) !?Value` (S1).** Pushes a `function_evaluation_from_game` frame onto the **live** state, runs it to that frame's return, and moves the output produced since the push into `text_writer`, truncating it from the stream. Every other side effect persists (globals, visit counts, RNG). It is legal only when `cont()` is not active, which ink also requires.
- **Inspection.** `current_choices`, `current_tags`, `global_tags`, `tags_for_content_at_path`, `visit_count_at_path_string`, `current_flow_name`, `alive_flow_names`, `current_errors`, `current_warnings`, `has_error`, `has_warning`.

### 4.8 VM (`src/runtime/vm.zig`)

- `run(program: *const ProgramView, state: *State, budget_steps: u32) RunResult` is a standalone hot function.
  - Inside it: `loop: switch (opcodes[pc]) { … continue :loop opcodes[pc]; }`
  - The step budget is a hard limit, and exhausting it returns `.budget_exhausted`.
  - `RunResult` also reports `.newline_reached`, `.external_unsafe_in_lookahead`, `.choices_ready`, `.done` and `.end`, so the Continue loop (§4.6) sits outside the hot function.
- Native binary ops go through `inline .add, .subtract, … => |opcode| binary(comptime opcode, …)`. Each handler is a small pure function.
- **Weave heuristics are removed** after root-causing them (P5.2).
- External functions are bound by name at the control plane and called by `ExternalIndex`. Arguments are a slice view of the evaluation stack.
- `RANDOM(min, max)` and shuffles use `dotnet_random.zig`, seeded exactly as ink seeds them (`story_seed + previous_random`, and `path_hash + loop index + story_seed`).

### 4.9 Loader

The current `json_loader.zig` becomes `src/core/program_builder.zig` plus `src/core/ink_json.zig`.

- **Pass 1** streams the input with `std.json.Scanner` into the builder. Container nesting is tracked on an explicit `WorkStack`, not by recursion. Both **ink.json v20 and v21** are accepted; version differences are listed in a table in `ink_json.zig` and covered by tests.
- **Pass 2** resolves paths into indices. Unresolvable paths are a load error with a diagnostic.
- The arena is sized from the JSON length. After `finish()` the result is copied into exact-size frozen slices, then `Program.verify()` runs.

### 4.10 Save format (D15)

- **Format.** Byte-compatible with C# ink save format v10, in both directions:
  - `flows` (each with `callstack`, `outputStream`, `currentChoices`, `choiceThreads`)
  - `currentFlowName`
  - `variablesState`
  - `evalStack`
  - `visitCounts`, `turnIndices`, `turnIdx`
  - `storySeed`, `previousRandom`
  - `inkSaveVersion`, `inkFormatVersion`
  - Ink-style serialized values (`^->`, `^var`/`ci`, lists with `origins`)
  - Older save versions that ink still loads (minimum version 8) are accepted.
- **Writing.** `to_json(writer)` streams through a `std.Io.Writer` using an explicit work stack. There is no intermediate buffer and no allocation.
- **Reading.** `load_json(json)` parses with `std.json.Scanner` into a **fixed scratch region** sized by `Limits`. It never touches the live state until the whole document has validated. Then it commits, and `State.verify()` runs. A failed load leaves the story unchanged.
- **Paths.** Path strings in saves are resolved with `path.zig`. Paths that don't resolve (the story changed since the save) produce a warning and fall back to ink's behaviour.
- **Interop.** C#-produced saves are checked into `test/fixture/saves/`. Round-trip tests run in both directions.

### 4.11 Compiler front end

- **Source space.** All files of a compilation are loaded into one source buffer. Each INCLUDE is appended when it is discovered, and a `FileIndex` table maps byte ranges to paths. Token offsets, `TokenIndex` and `NodeIndex` are therefore global, and the side tables need no file qualifier. Diagnostics map offsets back to `file:line:column`.
- **Tokenizer:**
  - Mode-aware (line-start, content, logic/expression, choice, brace-header, string). The parser selects the mode.
  - SoA tokens with stored `start` and `end` (T2 deviation). Real keyword and operator tags.
  - A line-start table for `line:column`.
  - The token count is bounded by `source.len + 1` (asserted).
  - The labeled-switch state machine is the second D10 exception.
- **Parser (non-recursive, D9):**
  - Uses zirp's node layout and recovery model, driven by an explicit state stack.
  - **Weave nesting** is already level-based in ink (`*`, `**`, `-`, `--`), so it maps to a stack of open weave levels.
  - **Inline braces `{…}`** use a bounded brace stack. Multi-line `{ … }` blocks may contain weaves that contain choices that contain inline braces, so the parser state stack is a single heterogeneous stack of frames tagged by construct, not one stack per construct.
  - **Expressions** use an operator-precedence (shunting-yard/Pratt) loop with explicit operand and operator stacks.
  - Each of these stacks has a nesting limit (`parse_depth_max`); exceeding it is a diagnostic, not a crash.
  - Backtracking means restoring the token index and node/stack/error counts.
  - The design is validated by a spike before the grammar work starts (P7.0).
- **Diagnostics:** `Diagnostic { tag, token: TokenIndex, extra }`, capped at `errors_max`. `compile()` returns `Result { program, diagnostics }`.

### 4.12 Compiler middle and back end

- **Sema/resolve:** an iterative traversal using contiguous children and a `WorkStack`. It builds scoped symbol tables (global, knot, stitch, weave labels, parameters, temps per knot/function) keyed by `StringId`, plus side tables keyed by `NodeIndex`.
- **Lowering:** AST to `ProgramBuilder` in one iterative pass with backpatch stacks (T19) and a shared buffer for nested containers (T10).
- **Container layout must match inklecate exactly**: naming (`c-N`, `g-N`, `s`N, `b`), nesting and flags. Shuffle seeds hash the container path, and saves store paths, so any layout difference changes runtime behaviour and breaks save interop.
- **`ink_json.serialize(Program)`:** an inklecate-compatible writer, iterative over the container tree.

---

## 5. Decisions (all confirmed 2026-10-24)

### 5.1 Core design (D1–D11, confirmed as recommended)

- **D1 Instruction layout:** **5 B SoA (`opcode` u8 + `operand` u32) plus `extra`.**
- **D2 Container model:** **containers stay as the unit of addressing, with one contiguous instruction array.** Full linearisation (P6b) is a stretch goal, gated by benchmarks. It must preserve the visit-counting semantics of §4.6.
- **D3 Temps:** **a per-frame linear `{StringId, Value}` array, bounded.**
- **D4 Runtime strings and lists:** **a fixed-capacity StateHeap and list slab, sliding mark-compacted when an allocation fails.** This satisfies TigerStyle's "no allocation after init". Refcount/COW is rejected because it needs either an allocator or a free list, and it puts rc traffic on the hot path.
- **D5 `cont()` result:** **a borrowed slice, valid until the next mutating call**, plus a `cont_alloc(gpa)` convenience. This is a breaking change.
- **D6 Zig version:** **0.17.0.**
- **D7 Compiler output:** **`Program` is primary.** `.ink.json` is just a serialization, and the JSON path remains the e2e oracle until P9.
- **D8 Naming:** **adopt TigerStyle snake_case for all functions, including the public API** (`cont`, `can_continue`, `current_choices`, `choose_choice_index`, `choose_path_string`, `get_variable`, `set_variable`, `bind_external_function`, `observe_variable`, `evaluate_function`, `to_json`, `load_json`, `switch_flow`, …). Files are snake_case too (`string_pool.zig`, not `StringPool.zig`). The API is breaking anyway (D5, D12), so rename once, in P6.3. Docs and memory get updated in P9.3.
- **D9 Recursion:** **zero recursion in new code**, enforced by a call-graph lint. The front end uses an explicit-stack parser; traversals use post-order or work stacks. The alternative was recursion guarded by a depth assertion. It is simpler to write, but it violates the rule and makes native stack use input-dependent.
- **D10 Function-length exceptions:** **exactly two documented exceptions to the 70-line rule**: `vm.run`'s labeled switch and the tokenizer's labeled-switch state machine. In both, each prong is at most about 3 lines and delegates to a pure helper. The alternative is a two-level dispatch, which costs an extra indirect branch per instruction or byte.
- **D11 Assertion builds:** **ship ReleaseSafe as the default**; ReleaseFast is opt-in. Per §3.2 the hot path only uses `std.debug.assert`. Performance targets apply to ReleaseSafe.

### 5.2 Gap-review decisions (D12–D16)

- **D12 `cont()` granularity: line-based, like ink's `Continue()`,** with newline lookahead (snapshot plus undo log, §4.6), plus `continue_maximally()`. This costs a second copy of the live-flow stacks (the lookahead snapshot) in the memory budget.
- **D13 Ground truth: ink C# semantics.** The old runtime is an oracle with a divergence ledger, not a reference. The divergences S1–S9 (§1.1) are fixed in the new runtime, not reproduced.
- **D14 Scalars: i32 with wrapping arithmetic and f32, exactly as C# ink.** Literals are inline in the operand, there are no constant pools, and `Value` is 12 B.
- **D15 Saves: byte-compatible with C# ink in both directions** (§4.10).
- **D16 Compiler migration: retarget first.** P8.0 points the old codegen at `ProgramBuilder`, so the e2e tests run on the new VM early. Then the new front end replaces the old one, after a parser spike (P7.0).

---

## 6. Phased work breakdown

Every item has **success criteria validated by unit tests**, per the project rule. Every task's implementation notes must contain a back-of-envelope sketch (§3.2). New code must pass the P0.8 lint. Items in the same phase can mostly run in parallel.

Terms: "oracle" refers to P0.4, "ground truth" to P0.10, and "ledger" to the divergence ledger in P0.4.

The CLAUDE.md rule "do not parse all fixtures" limits what an agent reads into its context while working. Test runners and tools (transcripts, oracle, simulator, structural compare) do iterate over every fixture.

### Phase 0: Safety net, baseline, tooling

- **P0.1 Zig 0.17 compatibility.** Replace `dupeZ` and bump `build.zig.zon`.
  - ✅ `zig build test` on 0.17.0 passes 549/549.
- **P0.2 Split build steps.** Add `test-runtime`, `test-compiler`, `test-core`, `bench`, `lint`, `fuzz` and `simulate`, plus `-Dtest-filter`. Remove the unused module.
  - ✅ Each step runs on its own, and the totals match the full suite.
- **P0.3 Transcript corpus tool** (`tools/transcript.zig`).
  - Runs every compiled fixture with a deterministic choice policy (a seeded choice index sequence), a **turn cap** (`transcript_turns_max`) and a step cap.
  - Writes `*.transcript` files recording every `cont()` result with its tags, the choices per turn, and the final variables.
  - Line-level records allow comparison with the line-based new runtime. For the old engine, its turn output is split at newlines.
  - ✅ A test regenerates the transcripts and the diff is empty. A looping story stops at the cap with a recorded marker.
- **P0.4 Differential oracle harness and divergence ledger.** Runs old vs new engine (or old vs stored transcripts) turn by turn.
  - `test/divergence_ledger.zon` lists every known difference with:
    - fixture and turn
    - kind (S1–S9 or new)
    - reason
    - the ground-truth source that justifies the new behaviour
  - The oracle fails on any difference that is not in the ledger, **and on any ledger entry that no longer diverges**, so stale entries get removed.
  - ✅ A seeded divergence reports the first differing turn. A ledgered divergence passes. A stale ledger entry fails.
- **P0.5 Allocation-counting allocator.**
  - ✅ A self-test passes. The "zero allocation in cont" test against the old runtime is recorded as skipped, with the reason.
- **P0.6 Benchmarks** (`tools/bench.zig`, ReleaseSafe and ReleaseFast).
  - Measures load time, `cont()` steps/s, bytes per instruction/node, peak RSS and compile time on `crime_scene` and a generated large story.
  - ✅ The baseline for both modes is committed to `docs/benchmarks.md`.
- **P0.7 Verify and record the audit bugs.** Each becomes a failing test, skipped with a task id. Zero-debt rule: all must be fixed by P9.
  - Runtime:
    - `loadStateFromJson` keeps keys that point into freed memory
    - divert, divert-target and variable-pointer values are serialized as `null`
    - saved strings are truncated at 2048 bytes
    - choices, flows, tags and the seed are not saved
    - `story_seed` never advances
    - variable lookup walks every frame
    - `aliveFlowNames` doesn't compile
    - the 33rd temp is undefined behaviour
    - the semantic divergences S1–S8 (§1.1), each with a minimal reproduction and the expected ink output
  - Compiler:
    - label names collide globally across knots
    - `temp_names` is never reset
    - INCLUDE is unresolved
    - list auto-numbering is wrong
    - `compile()` ignores errors
- **P0.8 TigerStyle lint tool** (`tools/lint.zig`, `zig build lint`). It checks:
  - function length ≤ 70 lines, with allowlist entries for `vm.run` and the tokenizer state machine (D10)
  - line length ≤ 100 columns
  - no recursion: a name-based call-graph cycle check using `std.zig.Ast` over `src/`, with `// lint: not-recursive <reason>` suppressions for false positives, plus a per-directory allowlist so old code can be grandfathered until it is deleted
  - no `usize` struct fields
  - snake_case file names
  - an assertion-density report (asserts per function) that fails new modules averaging below 2
  - ✅ The lint passes on `src/core/` from day one. A tests-for-the-linter suite shows each rule firing on sample inputs, including a suppressed false positive.
- **P0.9 Fuzz and simulation harness.**
  - `zig build fuzz` targets: tokenizer, parser, JSON loader, save load, and the save/load round trip.
  - `tools/simulate.zig` is a VOPR-style deterministic simulator. From a seed, it plays every fixture with:
    - random choices
    - random save/load points
    - random flow switches
    - random `evaluate_function` calls
    - random `set_variable` calls
    - an optional "compact before every allocation" mode

    It runs `State.verify()` after every `cont()`.
  - ✅ The harness runs (targeting the old runtime first) and is reproducible by seed.
- **P0.10 Ground-truth corpus.**
  - Pin a commit of the inkle/ink repository and transcribe the relevant runtime tests from `tests/Tests.cs` into `test/ground_truth/<name>.ink` plus `<name>.expected` (line-by-line output, tags, choices, and, where the test checks them, variables, errors and warnings). This happens once. The tool is a `tools/` program where possible, otherwise the transcription is done by hand and reviewed.
  - Compile each case with inklecate into `<name>.ink.json`.
  - Priority coverage: S1–S9, threads, choices in threads, flows, evaluate-function side effects, glue and newline lookahead, visit and turn counts, shuffles and `RANDOM` with a seed, list ops, int and float edge cases, save/load.
  - ✅ A runner executes every case against the old runtime. Results go into the ledger as pass or fail-with-reason, and this becomes the starting state of the ledger.
- **P0.11 Engine-neutral test layer** (`test/harness.zig`).
  - `run(story_source_or_json) -> Session`, `expect_line`, `expect_lines_until_choice`, `expect_choices`, `choose`, `expect_variable`, `expect_error`, `save`/`load`.
  - The layer is implemented for both engines. The old engine adapter splits turn output into lines.
  - Runtime tests are migrated onto the layer **before** P4, so they move once and run against both engines.
  - ✅ The migrated tests pass on the old engine. The share of runtime tests that still use internal fields is reported, and the target is zero before P9.1.
- **P0.12 Weave-heuristic instrumentation.** Count how often `loopBackGatherTailPeel` and `divertTargetsAncestorOfAnyChoiceSource` fire, separately for inklecate-compiled fixtures and for inkz-compiled stories.
  - ✅ A report in `docs/benchmarks.md` lists each fixture where a heuristic fires, split by compiler. P5.2 uses this report to tell runtime gaps from compensation for old-compiler bugs.

### Phase 1: Core primitives (`src/core/`)

- **P1.1 `index.zig`.** ✅ Round-trip tests; `to_int(.none)` panics in a safe build (tested via a child process or `std.testing` panic hook); comptime size asserts.
- **P1.2 `limits.zig`.**
  - `bytes_total()` covers every buffer, including the lookahead snapshot, choice snapshots and flow parking.
  - ✅ Comptime relationship asserts compile. Runtime `Limits.verify()` rejects inconsistent options (negative space). A test pins the default `bytes_total()`.
- **P1.3 `string_pool.zig`.** ✅ Deduplication; id 0 is `""`; `find` never inserts; zero allocations during lookup; 100k strings round-trip; an invalid id asserts.
- **P1.4 `extra.zig`.** ✅ Round trip of a struct with u32, enum, packed and trailing-slice fields.
- **P1.5 `bounded_stack.zig` and `work_stack.zig`.** ✅ Overflow returns an error; `truncate` restores the previous length; `verify` catches a corrupted length (negative-space test).
- **P1.6 `tag_set.zig`.** ✅ Set algebra.
- **P1.7 `sizes_test.zig`.** ✅ Size asserts for every core type (`Value` 12 B; `OutputItem` ≤ 12 B; `Frame` ≤ 24 B; `Instruction` and `Node` 5 B in SoA; `Token` 9 B in SoA).
- **P1.8 `dotnet_random.zig`.** ✅ The first 1000 outputs of `Next()` and `Next(min, max)` match reference sequences from .NET for seeds 0, 1, 42, `maxInt(i32)` and negative seeds. Those sequences are checked in as test data.
- **P1.9 `path.zig`.** ✅ Parses and resolves absolute paths, relative paths, `^` and numeric components against a test container table. Rejects malformed paths with a named error. Zero allocations.

### Phase 2: Program image and builder

- **P2.1 `Opcode`, `Instruction` and operand encodings,** with typed `instruction_add`. ✅ Encode/decode round trip for every opcode, including the bit-cast i32 and f32 literals; comptime exhaustiveness.
- **P2.2 `ContainerInfo` SoA and the named table** (with `depth`, and `index_in_parent = none` for named-only containers). ✅ Named lookup compares u32s only; out-of-range lookups assert; the depth and parent invariants hold in `verify`.
- **P2.3 `ProgramBuilder`** with the fixup list and `finish()`, followed by `Program.verify()`. ✅ Contiguous nested containers; fixups resolve; unresolved targets produce a diagnostic; a corrupted program fails `verify` (negative space).
- **P2.4 Path and hash tables.** ✅ Every container path and `path_hash` in `crime_scene` matches what ink computes for the inklecate-compiled JSON (ground truth), not only what the old runtime computes.
- **P2.5 Globals, lists and externals tables.** ✅ Tests on a small lists fixture.
- **P2.6 `program.dump(writer)`** (iterative). ✅ Snapshot test.

### Phase 3: JSON → Program loader

- **P3.1 Streaming loader** (no `std.json.Value` tree, explicit `WorkStack`, v20 and v21). ✅ Every compiled fixture loads, including all 5 v20 fixtures. No allocations after `finish()`. Peak memory is below the old loader's. Fuzz target added.
- **P3.2 Load-time path resolution** for every target kind. ✅ A scan asserts that no operand refers to a path string, and `verify` passes.
- **P3.3 Structural parity with the old `Story.containers`.** ✅ Parity on every fixture.

### Phase 4: Runtime state

- **P4.1 `Value` and native op semantics** (i32 wrapping, f32, C# formatting and conversions). ✅ The `evaluation.zig` tests are ported, plus overflow-wrap, division-by-zero, `minInt / -1`, and float-formatting tests taken from ground truth.
- **P4.2 List slab bitsets and all list builtins.** ✅ All list tests ported; display order; empty-list origins.
- **P4.3 StateHeap with sliding mark-compact, triggered when an allocation fails.** ✅
  - Heap use stays bounded over 10k turns of string concatenation.
  - A single `cont()` that builds more garbage than the heap holds succeeds through mid-run compaction.
  - Every root kind listed in §4.5 survives compaction (one test per kind).
  - `error.HeapLimit` is returned on a true overflow.
  - Debug poisoning catches a stale reference (negative test).
- **P4.4 Flat frames, threads and temps; fork by range copy.** ✅ Callstack tests ported; fork/pop restores state exactly; every limit returns its named error.
- **P4.5 `OutputItem` stream and `string_marks`.** ✅ Every newline/glue/whitespace test passes.
- **P4.6 Choices SoA with tag ranges and the real thread index.** ✅ Choice tag tests.
- **P4.7 Choice thread snapshot area** (S5), with sharing of consecutive identical snapshots. ✅ A choice generated inside a thread restores that thread when chosen, verified by a ground-truth case; snapshot sharing is verified; `choice_snapshot_frames_max` overflow returns its error.
- **P4.8 Flows with parking** (§4.5). ✅ Multiflow tests; listing alive flow names works; switching flows N times keeps the bytes in use bounded; removing a flow compacts the parking region; parking overflow returns its error.
- **P4.9 Lookahead snapshot and undo log** (§4.6). ✅ Take/restore leaves the state bit-identical (checked by `verify` plus a state hash). The undo log reverts globals, visits, turns and the RNG. The heap mark is valid after a compaction during lookahead. Log overflow returns its error.
- **P4.10 Errors and warnings lists.** ✅ They are bounded, cleared at the right points (ink semantics), and saved where ink saves them.
- **P4.11 `State.verify()`.** ✅ It catches each seeded corruption: a frame range out of bounds, a dangling `StringReference`, temps outside their frame, a snapshot range out of bounds, and a corrupt parking directory.
- **P4.12 Memory budget.** ✅ `Story.init` allocates exactly `Limits.bytes_total()` bytes (counting allocator). A documented sizing example for a realistic game (several stories, several flows each) is in `docs/benchmarks.md`.

### Phase 5: VM

- **P5.1 Labeled-switch `vm.run` with a step budget and `RunResult` signals.** ✅ Oracle passes on the basic, text and divert subset; budget exhaustion is tested.
- **P5.2 Root-cause and remove the weave heuristics.** Use the P0.12 report. For each firing, write a minimal reproduction and classify it as a runtime semantic gap (fixed in the VM) or compensation for old-compiler output (recorded for P8.0/P8.4, and not fixed in the old compiler).
  - ✅ Every inklecate-compiled reproduction passes on the new VM with no heuristic code. The compiler-side reproductions are linked from P8.4.
- **P5.3 Variables:** global slots, frame temps, variable pointers with `context` index and ink-exact scoping. ✅ Tests plus a scoping regression test, including pointers to temps passed into functions.
- **P5.4 Functions, tunnels, threads, externals** (index table, arguments as a stack view, fallbacks, `lookahead_safe`). ✅ Ported tests; zero allocations; a non-lookahead-safe external is not called during lookahead (ground truth).
- **P5.5 Line-based `cont()`** (§4.6, D12) and `continue_maximally`. ✅ The ground-truth glue and newline cases pass line by line, and tags attach to the correct line.
- **P5.6 Visit counting on divert** (S3/S4): common-ancestor walk and `count_start_only`. ✅ Ground-truth cases for diverts into nested stitches and gathers, `count_start_only`, and turn indices.
- **P5.7 Observers,** queued per `cont()` and batched. ✅ Each observer fires once per variable per `cont()`, after output. `set_variable` outside `cont()` fires immediately.
- **P5.8 `evaluate_function`** (S1, §4.7) on the live state. ✅ The `evaluating_ink_functions_from_game*` tests pass. A ground-truth case proves that a global changed inside the function persists. Output is captured and truncated. A call during `cont()` or from a callback returns `error.Reentrant`. Zero allocations.
- **P5.9 Randomness** (S7): `RANDOM`, `SEED_RANDOM`, shuffles, and advancing `story_seed`/`previous_random`. ✅ Seeded ground-truth cases produce identical sequences.
- **P5.10 Errors and warnings** raised at ink's points (ran out of content, unknown variable, and so on), plus the error handler. ✅ Ground-truth error cases.
- **P5.11 Zero-allocation gate.** ✅ Every fixture runs `cont`, `choose_choice_index`, `evaluate_function`, `set_variable` and `switch_flow` with 0 allocations after init.
- **P5.12 Full parity and simulator.** ✅ Every ground-truth case passes. The oracle passes on every fixture modulo the ledger. All runtime tests run on the new engine through P0.11. `simulate` runs 10k seeds (including compact-always mode) with no verify failure.

### Phase 6: Save/load and public API

- **P6.1 `to_json(writer)`** (§4.10; streaming, iterative, zero allocation). `State.verify()` runs before saving. ✅ The P0.7 save bugs are fixed and their tests un-skipped. The output of a C#-identical state equals the checked-in C# save byte for byte, modulo JSON key order if ink's writer order is not stable (to be checked).
- **P6.2 `load_json`** (fixed scratch, validate-then-commit, path resolution through `path.zig`). `verify()` runs after loading (pair assertion with P6.1).
  - ✅ Save, load, then continue produces the same transcript as an uninterrupted run, at every turn of every fixture.
  - Every C#-produced save in `test/fixture/saves/` loads and continues identically to C#.
  - A corrupted save leaves the story unchanged.
  - Zero allocations.
  - The fuzz target is added.
- **P6.3 Public API (D5, D8, §4.7).**
  - In-place `story.init(gpa, program, options)` and `story.init_from_json`.
  - snake_case methods; `Story.Options{ limits }`; `cont_alloc`; `get_variable`/`set_variable`.
  - The public `Value` type is used in callbacks.
  - Borrowed-view generation stamps in Debug.
  - Callbacks come last in each parameter list.
  - ✅ An API test exercises every public method, including every limit error. A stale-view access asserts in Debug. Two stories share one `Program` and run independently. A reentrant call from a callback returns `error.Reentrant`.
- **P6b (stretch, gated by benchmark) Full linearisation.** ✅ Ground truth and oracle still pass (including the visit-count cases) and throughput improves by at least 15%; otherwise the change is dropped.

### Phase 7: Compiler front end

- **P7.0 Parser spike (time-boxed, throwaway).** Build the explicit-stack parser skeleton for the hardest nesting: a multi-line `{ cond: … - else: … }` containing a weave with choices whose `[...]` and inline `{…}` nest, plus expressions inside. Use the heterogeneous state stack and recovery.
  - ✅ The spike parses 5 hand-picked hard fixtures into the planned node layout. A written go/no-go note records the design adjustments for P7.3.
- **P7.1 Mode-aware tokenizer** (stores `end`; D10 exception). ✅ Rewritten tests; every `.ink` fixture tokenizes without `invalid` tokens; the stream ends with `eof` at `source.len`; fuzz target added.
- **P7.2 `ast.zig`:** 5 B nodes, typed views, `to_typed()`, comptime exhaustiveness. ✅ Size guards plus the coverage check.
- **P7.3 Explicit-stack parser core:** state stack, scratch stack, `marker`/`wrap`, gas counter, `parse_depth_max`. ✅ 10k-deep nesting yields a diagnostic, not a crash; the progress invariant is tested.
- **P7.4 Grammar, top level** (INCLUDE, VAR, CONST, LIST, EXTERNAL, knots, stitches, functions). ✅ Snapshots.
- **P7.5 Grammar, content** (text, glue, tags, inline braces, sequences, diverts, tunnels, threads). ✅ Snapshots.
- **P7.6 Grammar, weave** (choices, `[]` content, conditions, labels, sticky choices, fallbacks, gathers, nesting). ✅ Snapshots.
- **P7.7 Grammar, logic and expressions** (iterative precedence parser). ✅ Precedence tests ported.
- **P7.8 Resilience and diagnostics.** ✅ A resilience corpus with `// inkz-error` markers; later knots still parse after errors.
- **P7.9 Snapshot harness** (`tools/snapshot.zig`, `SNAP_UPDATE=1`). ✅ Self-tests.
- **P7.10 Port the 51 parser shape tests.** ✅ All pass.

### Phase 8: Compiler sema and lowering

- **P8.0 Retarget the old codegen to `ProgramBuilder`** (D16). This is a thin adapter from `CContainer` to the builder, so the old front end feeds the new VM. ✅ All 209 e2e tests pass via the old front end → Program → new VM, with differences only where the ledger lists them.
- **P8.1 Scoped symbol tables and the iterative resolve pass.** ✅ The same label in two knots resolves correctly; temps are scoped; forward references work; unresolved names produce a diagnostic.
- **P8.2 INCLUDE resolution** into the shared source space (§4.11; Io-based; bounded include depth and file count; cycle detection). ✅ The include fixtures pass; an include cycle produces a diagnostic; diagnostics in included files report the right `file:line:column`.
- **P8.3 Constants and lists** (auto-numbering fixed). ✅ Regression test.
- **P8.4 Lowering to `ProgramBuilder`** (one iterative pass, backpatch stacks, inklecate-identical container layout). It replaces P8.0's adapter, and the compiler-side reproductions from P5.2 are covered here. ✅ All 209 e2e tests pass via compile → Program → new VM.
- **P8.5 `ink_json.serialize` and the structural gate.** ✅ `load(serialize(compile(source)))` equals `compile(source)` (verified pair). The exact-JSON test passes. **Every** fixture that has an inklecate-compiled `.json` passes a structural compare (container names, nesting, flags, instruction sequence), with differences only where the ledger lists them.
- **P8.6 Compiler performance and allocation discipline.** ✅ The benchmark shows at least 2× less memory than baseline. The compile arena is sized from the source length and retries at most `compile_retries_max` times.

### Phase 9: Removal, rule enforcement, docs

- **P9.1 Delete the old runtime.** This also retires the oracle: ground truth plus the stored transcripts remain. ✅ Suite green; lint allowlist for runtime removed; no test uses internal fields.
- **P9.2 Delete the old compiler.** ✅ Suite green; lint allowlist emptied; all P0.7 skips are gone; the ledger contains no entries caused by old code.
- **P9.3 Documentation.**
  - Rewrite `docs/Architecture.md`.
  - Update `docs/Guidelines.md`, merging the TigerStyle rules from §3 with the DOD rules (index newtypes, no pointers in persistent data, `string_pool`, `bounded_stack`, size guards, zero-allocation gate, no recursion, limits, the view-lifetime contract).
  - Update `docs/ArchitectureAndDevOverview.md` and `docs/RunningYourInk.md` for D5, D8 and D12, with a migration table.
  - Update the project memory and the API conventions.
  - ✅ Doc code samples compile in a doctest step.
- **P9.4 Final benchmark report** (ReleaseSafe and ReleaseFast).

---

## 7. Dependency graph

```
P0 ─┬─> P1 ─> P2 ─> P3 ─> P4 ─> P5 ─┬─> P6 ─> P9.1
    │                               │    └─> P6b (optional)
    │                               ├─> P8.0 (old codegen → builder, D16)
    │                               └─> P8.4 (needs builder + new VM)
    ├─> P0.10/P0.11 before P4 (ground truth + neutral tests)
    ├─> P0.12 before P5.2
    └─> P1 ─> P7.0 spike ─> P7 ─> P8.1–P8.3 ─> P8.4 ─> P8.5 ─> P9.2
P0.8 lint gates every phase. P9.3/P9.4 after P9.1 + P9.2.
```

---

## 8. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Oracle freezes old bugs | D13: ground truth from ink's tests (P0.10); divergence ledger with stale-entry detection (P0.4) |
| Weave heuristics hide real semantic gaps, or compensate for old-compiler bugs | P0.12 instrumentation split by compiler; P5.2 classifies each firing; compiler-side cases are fixed only in the new lowering |
| Line-based lookahead is subtle (glue, tags, externals, heap) | §4.6 spelled out; ground-truth glue cases; P4.9 bit-identical restore test; simulator |
| Mid-turn heap exhaustion | Compaction when an allocation fails, at any safepoint; a test per root kind; compact-always simulator mode |
| Memory blow-up from per-flow, per-choice and lookahead copies | Parking packs only used prefixes; snapshot sharing; `bytes_total()` pinned by a test; sizing example |
| Host keeps a view past compaction | Contract "valid until the next mutating call"; Debug generation stamps |
| Save-format compatibility | D15 byte-compatible; C# saves checked in; save/load/continue oracle; validate-then-commit; fuzzing |
| Inklecate layout mismatch changes shuffles and saves | §4.12 rule; P8.5 structural gate on every inklecate fixture |
| Mark-compact bugs | Paired `verify` before and after; Debug poisoning; the simulator compacts on every allocation in Debug |
| Fixed limits too small for real stories | Generous defaults; `Options.limits`; named overflow errors; the benchmark story sets the defaults |
| Non-recursive parser harder to write than recursive descent (highest schedule risk) | P7.0 spike with go/no-go; heterogeneous state stack; snapshot corpus built first; P8.0 keeps the old front end usable meanwhile |
| Recursion lint false positives | Name-based check with reasoned suppressions; tests for the linter |
| 70-line limit forces awkward splits | Push ifs up and fors down; two documented exceptions (D10) |
| Public API rename (D8, D12) breaks users | One breaking release; a migration table in `RunningYourInk.md` |
| Big-bang risk | Strangler: old and new coexist until P9; D16 compiler retargeting; every phase merges green |
| Assertion overhead in the hot path | Control/data plane split; `std.debug.assert` only in `vm.run`; verify per `cont()`; targets measured in ReleaseSafe (D11) |

---

## 9. Success metrics (final acceptance)

- 100% of behavioural tests pass, plus the ground-truth, oracle (modulo the ledger), save/load/continue, C# save interop, resilience, snapshot, fuzz and simulation (10k seeds, including compact-always) suites.
- The divergence ledger contains only entries where inkz deliberately differs from ink, each with a documented reason. The target is empty.
- **0 allocations** in `cont`, `choose_choice_index`, `evaluate_function`, `set_variable`, `switch_flow` and `load_json` after init (test-enforced).
- `Story.init` allocates exactly `Limits.bytes_total()` (test-enforced).
- **0 recursion, no function over 70 lines** (except the two D10 exceptions), no line over 100 columns, an assertion density of at least 2 per function in `src/`. `zig build lint` passes with an empty allowlist.
- The VM hot path contains no path-string resolution, no string hashing and no `mem.eql` (lint grep gate on `vm.zig`).
- Memory stays bounded over 10k turns (test-enforced).
- Size guards hold: `Value` 12 B; `Instruction` and `Node` 5 B SoA; `Token` 9 B SoA.
- Benchmarks (ReleaseSafe): `cont()` throughput at least 3× baseline, load at least 2× faster, compiler peak memory at least 2× lower. These targets will be revised after P0.6.
