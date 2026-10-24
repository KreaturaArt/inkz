# DOD Migration Plan — full data-oriented inkz (TigerStyle edition)

Status: proposal, revision 2 (2026-10-24). Sources: audits of `src/runtime` and `src/compiler`, plus the reference projects `reference/fino` and `reference/zirp`. Engineering rules come from `TIGER_STYLE.md` (repo root).

Revision 2 changes: TigerStyle is now a first-class constraint. That brought a new section §3 ("Engineering rules"), renamed identifiers (snake_case files, no abbreviations), no recursion anywhere, explicit limits, assertion density and paired verification, function and line limits, Zig-only tooling, fuzzing and simulation, and new decisions D8–D11.

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

**Compiler problems:**
- The tokenizer emits coarse `text` tokens, which are re-lexed as strings in a second `ExprParser`.
- It builds two recursive pointer trees (`Parsed.*` with 40–104 B nodes, then `CObject`/`CContainer`).
- Paths are strings (62 `allocPrint`s) and opcodes are strings.
- The symbol table is global and unscoped.
- It produces no usable diagnostics.

**Target design** (zirp for the front end, fino for the IR/VM, TigerStyle for the engineering rules):

1. **Tokens.** SoA `{tag: u8, start: u32}` produced by one mode-aware labeled-switch lexer.
2. **AST.** SoA `{tag: u8, payload: u32}`, 5 bytes per node, children stored contiguously. It is built by a **non-recursive**, explicit-stack parser with resilient grammar (`.missing` nodes and an error array).
3. **Program** ("story image"). One immutable, interned, pre-resolved bytecode image, **shared by the compiler output and the JSON loader**. It contains:
   - SoA instructions `{opcode: u8, operand: u32}` plus an `extra: []u32` side table
   - constant pools
   - the string pool
   - the container table
   - the list item table
   - the global table
4. **Runtime state.** Every buffer is **statically allocated at init** with explicit limits and checked overflow:
   - a flat frame array (threads are ranges into it)
   - a flat temp array
   - a compact output stream
   - a 16-byte `Value`
   - a fixed-size string/list heap compacted at turn boundaries

   `cont()` performs zero allocations, and a test enforces this.
5. **Dispatch.** A labeled-switch threaded interpreter in a standalone hot-loop function with primitive/slice arguments, using `inline` prongs and `comptime opcode` for native ops.
6. **Safety.** Every function averages at least 2 assertions. `Program.verify()` and `State.verify()` are pair-checked (after build and after load; before save and after load). Compile-time size and relationship asserts. Fuzzing plus a deterministic story simulator.

**Migration** uses a strangler pattern. The new Program and VM are built alongside the old code, and a **differential oracle** (old runtime vs new runtime, same transcript over every compiled fixture) gates each step. Old code is deleted at the end. The 549/549 baseline stays green on every merge. "Zero technical debt" applies to new code from the first commit; old code is exempt only until it is deleted.

---

## 1. Baseline facts (measured 2026-10-23)

- `zig build test` with **Zig 0.16.0** passes 549/549.
- With the default **Zig 0.17.0** the build fails because `Allocator.dupeZ` is gone (`parser.zig:25`, `tokenizer.zig:359` ×2). The replacement is `dupeSentinel`.
- Tests:
  - about 220 runtime unit tests, 199 of them in `story.zig`
  - 51 parser shape tests
  - 28 tokenizer tests
  - 209 compiler e2e tests (output-text based, `compiler_helpers.zig`)
  - 11 runtime fixture tests
  - about 14 codegen/serializer/c2r/parity tests
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
  - CamelCase-free file names already match the rule

---

## 2. Techniques adopted from the references

| # | Technique | Source | Applied in inkz |
|---|---|---|---|
| T1 | `enum(u32) { none = maxInt, _ }` index newtypes | fino `index_sea/Parser.zig:9`, zirp `Ast.zig:55` | `ContainerIndex`, `InstructionIndex`, `StringId`, `NodeIndex`, `TokenIndex`, `GlobalSlot`, `ListItemIndex`, `ListOriginIndex`, `ExternalIndex`, `FlowIndex` |
| T2 | Token = `tag` u8 + `start` u32 in separate arrays; the end is recovered by re-lexing from a hint | zirp `Tokenizer.zig:65-110` | compiler tokens, 5 B |
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
- From zirp: the recursive grammar functions. We keep the node layout and recovery model but drive them from an explicit stack (D9).

---

## 3. Engineering rules (TigerStyle, applied to inkz)

These rules apply to **all new code** and are checked in review and by tooling (P0.8). Each rule says how it is enforced.

### 3.1 Safety

| Rule | inkz application | Enforcement |
|---|---|---|
| **No recursion** | Parser, sema, lowering, JSON loader/writer, save/load, list display, path printing, and the heap compactor all use explicit bounded work stacks, or rely on post-order layouts that need no stack. The VM is a flat loop; calls push frames onto a `BoundedStack`, never onto the native stack. | Lint: call-graph cycle check over `src/` (P0.8) |
| **A limit on everything** | `src/core/limits.zig` holds comptime defaults, overridable at runtime through `Story.Options.limits` and `Compiler.Options.limits`. Bounds include: frames, threads, temps, eval stack, output items, output bytes, choices, tags, heap bytes, flows, steps per `cont()`, parser nesting depth, errors, tokens/nodes per byte of source, include depth and file count. Every loop has a bound or an assertion that it terminates. | Overflow returns a named error (`error.FrameLimit`, …); tests for each limit |
| **Explicitly sized types** | `u32` indices and counts everywhere. `usize` only appears at slice-indexing boundaries, through `@as(usize, index)`. | Lint: `usize` in a struct field is an error |
| **≥ 2 assertions per function** | Preconditions on arguments, postconditions on results, invariants. Split compound asserts. Use `if (a) assert(b)` for implications. Assert both the positive and the negative space. | Lint: per-file assertion density report; review |
| **Pair assertions** | `Program.verify()` runs after `ProgramBuilder.finish()` (compiler path) and after JSON load (loader path). `State.verify()` runs before `to_json` and after `load_json`, and in Debug at every turn boundary. The heap compactor verifies before and after compaction. Serialization is checked by `load(serialize(p))` equal to `p`. | Tests call verify; Debug builds call verify at the boundaries |
| **Compile-time relationship asserts** | `comptime assert(@sizeOf(Value) == 16)`; `Opcode` fits u8; limits fit their index types (`frames_max <= maxInt(u24)` where packed); `ListItemIndex` count fits the bitset words. | Compile-time |
| **Static allocation** | Runtime: everything is allocated in `Story.init` and `load_json`, and nothing after (D4, P5.7). Compiler: allocation happens only in its init/compile phase, from an arena sized from the source length, with a bounded retry (T15). | Counting-allocator test gate |
| **Smallest scope, no aliases or duplicated state** | For example, the VM keeps `pc` and `container_index` in locals and writes them back to the frame only on call, return or yield. There is no cached copy elsewhere. | Review |
| **≤ 70 lines per function** | Push `if`s up and `for`s down. Parents own control flow and helpers stay pure. The VM dispatch switch is the single documented exception (D10). | Lint (P0.8) |
| **Strictest warnings, all errors handled** | No `catch unreachable` on operating errors and no `_ = try`-swallowing. Every error set is explicit on public functions. | Lint + review |
| **Explicit options at call sites** | `std.mem.sort(…, .{…})`, explicit `std.json` options, and so on. | Review |
| **Simple control flow** | Split compound conditions into nested `if`/`else`. State invariants positively (`index < count`). | Review |
| **Don't react directly to external events** | Variable observers are **queued** during `cont()` and dispatched in a batch at the end of the turn, which is also what reference ink does with `batchObservingVariableChanges`. External functions are called synchronously only at their defined instruction. Callbacks receive values, never pointers into state. | Test: observer fires once per turn per variable, after output |

### 3.2 Performance

- **Back-of-envelope sketch per phase.** Every phase task starts with a short sketch of memory bytes and cache lines touched per op (for example: an instruction is 5 B, so 64 B holds about 12 instructions; a `Value` is 16 B; a frame is ≤ 24 B). The sketch is recorded in the task's implementation notes before any code is written.
- **Control plane vs data plane.** Loading, verification, save/load and the compiler are the control plane, and assertions there are heavy. `vm.run()` is the data plane: assertions use `std.debug.assert`, which compiles out in ReleaseFast but stays in ReleaseSafe, and the verify passes run at batch boundaries (turns), not per instruction.
- **Batching.** The unit of work is `cont()` (one turn). Output text is assembled once per turn, observers are dispatched once per turn, and the heap is compacted once per turn.
- **Hot loops as standalone functions.** `vm.run()` takes primitive arguments and slices (`opcodes: []const Opcode`, `operands: []const u32`, `state: *State`), not `self: *Story`.

### 3.3 Developer experience

- **Naming.**
  - snake_case for files, functions and variables. This changes the public API too (D8).
  - No abbreviations: `container_index` not `cidx`, `instruction` not `inst`, `string_id` not `str_id`, `source`/`target` not `src`/`dest`.
  - Units and qualifiers come last: `frames_max`, `frames_count`, `heap_bytes_max`, `steps_max_per_turn`.
  - Keep **index**, **count** and **size** distinct in every name.
  - Proper acronym capitalisation: `JSONLoader`, `VMState`.
  - Related names have equal length where possible (`source_offset`/`target_offset`).
- **Struct ordering.** Fields, then types, then methods. Complex nested types move to top level.
- **Large structs.** Anything over 16 B is passed as `*const`. `Story`, `State` and `Program` are initialised in place through an out-pointer (`story.init(gpa, json, options)`).
- **Options structs.** Any function with two same-typed arguments takes an `options` struct.
- **Comments.** Full sentences that say *why*. Every test begins with a comment giving its goal and method.
- **Layout.** `zig fmt`, 4 spaces, at most 100 columns, braces on every multi-line `if`.
- **Zero dependencies, Zig-only tooling.** Transcript generator, lint, bench, fixture runner and snapshot updater all live in `tools/*.zig` (no shell or Python), wired as build steps.

---

## 4. Target architecture

### 4.1 Shared core (`src/core/`)

- `index.zig`: the T1 newtypes. Each has `.none`, `from_int` and `to_int`; `to_int` asserts `!= .none`.
- `limits.zig`: comptime defaults plus the `Limits` struct, with relationship asserts.
- `string_pool.zig` (T8):
  - storage is `bytes` (NUL-terminated entries; id 0 is `""`) plus an adapted table
  - API: `intern`, `get`, `find` (no insert), and `freeze() -> FrozenStringPool`
  - asserts that `get` is only called with ids it issued
- `extra.zig` (T9): `extra_add`, `extra_get`, `extra_reserve`, `extra_set`.
- `bounded_stack.zig`: a `BoundedStack(T)` over a fixed slice, with `push() error{…}!void`, `pop`, `peek`, `truncate(mark)` and `verify()`. It replaces every unchecked `appendAssumeCapacity`.
- `tag_set.zig` (T7).
- `work_stack.zig`: a bounded explicit stack used as the replacement for recursion in traversals. Pushing past the limit is an operating error, never undefined behaviour.

### 4.2 Program (immutable story image), `src/core/program.zig`

```zig
pub const Program = struct {
    strings: FrozenStringPool,
    instructions: std.MultiArrayList(Instruction).Slice, // opcode[], operand[]
    extra: []const u32,
    integers: []const i64,
    floats: []const f64,
    containers: std.MultiArrayList(ContainerInfo).Slice,
    named: []const NamedEntry,      // {name: StringId, container: ContainerIndex}, per container
    globals: std.MultiArrayList(GlobalInfo).Slice,
    list_origins: std.MultiArrayList(ListOrigin).Slice,
    list_items: std.MultiArrayList(ListItem).Slice,
    externals: []const ExternalInfo, // name, argument_count, fallback ContainerIndex
    root: ContainerIndex,

    pub fn verify(program: *const Program) void { ... } // pair assertion, see §3.1
};

pub const Instruction = struct { opcode: Opcode, operand: u32 }; // SoA: 5 B each
comptime { assert(@sizeOf(Opcode) == 1); }

pub const ContainerInfo = struct {
    instruction_first: InstructionIndex,
    instruction_count: u32,
    parent: ContainerIndex,
    index_in_parent: u32,
    name: StringId,               // .none if anonymous
    path: StringId,               // dotted path, used for save/load and choice ids
    path_hash: u32,               // precomputed Ink shuffle seed
    named_first: u32,
    named_count: u16,
    flags: ContainerFlags,        // visits / turns / count_start_only
    count_slot: u32,              // dense index into visit/turn arrays, or none
};
```

- **Opcode set.** `Opcode` is a single `enum(u8)` that merges `ControlCommand`, `NativeFunction` and the structural ops:
  - literals and output: `text`, `integer_small`, `integer_constant`, `float`, `bool`, `void`, `glue`, `newline`
  - flow: `enter_container`, `divert`, `divert_conditional`, `divert_variable`, `call_function`, `call_tunnel`, `call_external`, `start_thread`, `choice_point`
  - variables: `global_get`, `temp_get`, `global_set`, `temp_set`, `variable_pointer`
  - counts and targets: `read_count`, `divert_target`
  - lists: `list_literal`
  - all control and native ops
- **Targets are resolved before execution.** Operands are a `ContainerIndex`, or a `{container, index}` pair stored in `extra`. The hot path never sees a path string. `Program.verify()` asserts that every target operand is in range.
- **Newlines** have their own opcode and output-item kind, so the hot path does no `mem.eql` on `"\n"`.
- **One instruction array.** All container contents are stored contiguously; a nested container appears as `enter_container index` at its position in the parent.

### 4.3 Value (16 B, compile-time asserted)

```zig
pub const Value = union(enum(u8)) {
    null, integer: i64, float: f64, bool: bool,
    string: StringReference,       // u32; the high bit selects the program pool or the state heap
    divert_target: ContainerIndex,
    variable_pointer: VariablePointer, // packed(u32) { slot: u24, kind: u8 }
    list: ListReference,           // index into the state list slab
};
comptime { assert(@sizeOf(Value) == 16); }
```

### 4.4 Lists

- Each list item gets a global dense `ListItemIndex`. A list value is a fixed-width bitset in the state list slab: `div_ceil(list_items_count, 64)` words, plus an origin bitset.
- Set ops (union, intersect, difference, contains, equality, invert, all) are word-wise. Min, max and count use `@ctz`, `@clz` and `@popCount`.
- Display order comes from a precomputed `(origin, value)` table. Nothing is sorted at runtime and no strings are built.

### 4.5 Runtime state (`src/runtime/state.zig`)

Every buffer is sized from `Limits` once, in `Story.init`. Nothing grows after that.

```zig
evaluation:   BoundedStack(Value),
frames:       BoundedStack(Frame),        // every thread's frames, flat
threads:      BoundedStack(ThreadInfo),   // {frame_first, frame_count, index, pointer_previous}
temps:        BoundedStack(Temp),         // {name: StringId, value: Value}
output:       BoundedStack(OutputItem),   // {kind: u8, a: u32, b: u32}
string_marks: BoundedStack(u32),          // begin_string positions, so end_string is O(1)
choices:      bounded MultiArrayList(ChoiceRecord),
globals:      []Value,                    // indexed by GlobalSlot
visit_counts: []u32, turn_indices: []i32, // indexed by count_slot
heap:         StateHeap,                  // fixed bytes for strings + fixed list slab
flows:        BoundedStack(FlowState),
observer_queue: BoundedStack(GlobalSlot), // batched, see §3.1
```

- **Temp lookup** scans the current frame's temps comparing u32 ids. The scan is bounded by `temps_per_frame_max`, which is asserted. This keeps Ink's exact semantics.
- **Thread fork** copies the frame and temp ranges with `@memcpy`, with bounds asserted first.
- **StateHeap** has fixed capacity and is mark-compacted in place at the turn boundary. The roots are globals, temps, the evaluation stack, choices and flows. Running out of heap after compaction returns `error.HeapLimit`. Debug builds poison the vacated space and call `verify()` before and after compacting.
- **Output** is assembled into a fixed `output_bytes` buffer. `cont()` returns a borrowed slice that is valid until the next call (D5).

### 4.6 VM (`src/runtime/vm.zig`)

- `run(program: *const ProgramView, state: *State, budget_steps: u32) RunResult` is a standalone hot function.
  - Inside it: `loop: switch (opcodes[pc]) { … continue :loop opcodes[pc]; }`
  - The step budget is a hard limit, and exhausting it returns `.budget_exhausted`.
- Native binary ops go through `inline .add, .subtract, … => |opcode| binary(comptime opcode, …)`. Each handler is a small pure function.
- **Weave heuristics are removed** after root-causing them (P5.2).
- `evaluate_function` snapshots the state into a preallocated shadow `State`. There is no JSON round trip and no recursion: nested evaluation is rejected with `error.Reentrant`.
- External functions are bound by name at the control plane and called by `ExternalIndex`. Arguments are a slice view of the evaluation stack.

### 4.7 Loader

The current `json_loader.zig` becomes `src/core/program_builder.zig` plus `src/core/ink_json.zig`.

- **Pass 1** streams the input with `std.json.Scanner` into the builder. Container nesting is tracked on an explicit `WorkStack`, not by recursion.
- **Pass 2** resolves paths into indices. Unresolvable paths are a load error with a diagnostic.
- The arena is sized from the JSON length. After `finish()` the result is copied into exact-size frozen slices, then `Program.verify()` runs.

### 4.8 Compiler front end

- **Tokenizer:** mode-aware (line-start, content, logic/expression, choice, brace-header, string). The parser selects the mode. SoA tokens with hint-based re-lexing. Real keyword and operator tags. A line-start table for `line:column`. The token count is bounded by `source.len + 1` (asserted).
- **Parser (non-recursive, D9):**
  - Uses zirp's node layout and recovery model, driven by an explicit state stack.
  - **Weave nesting** is already level-based in Ink (`*`, `**`, `-`, `--`), so it maps to a stack of open weave levels.
  - **Inline braces `{…}`** use a bounded brace stack.
  - **Expressions** use an operator-precedence (shunting-yard/Pratt) loop with explicit operand and operator stacks.
  - Each of these stacks has a nesting limit (`parse_depth_max`); exceeding it is a diagnostic, not a crash.
  - Backtracking means restoring the token index and node/stack/error counts.
- **Diagnostics:** `Diagnostic { tag, token: TokenIndex, extra }`, capped at `errors_max`. `compile()` returns `Result { program, diagnostics }`.

### 4.9 Compiler middle and back end

- **Sema/resolve:** an iterative traversal using contiguous children and a `WorkStack`. It builds scoped symbol tables (global, knot, stitch, weave labels, parameters, temps per knot/function) keyed by `StringId`, plus side tables keyed by `NodeIndex`.
- **Lowering:** AST to `ProgramBuilder` in one iterative pass with backpatch stacks (T19) and a shared buffer for nested containers (T10).
- **`ink_json.serialize(Program)`:** an Inklecate-compatible writer, iterative over the container tree.

---

## 5. Decisions to confirm (recommendations in bold)

- **D1 Instruction layout:** **5 B SoA (`opcode` u8 + `operand` u32) plus `extra`.**
- **D2 Container model:** **containers stay as the unit of addressing, with one contiguous instruction array.** Full linearisation (P6b) is a stretch goal, gated by benchmarks.
- **D3 Temps:** **a per-frame linear `{StringId, Value}` array, bounded.**
- **D4 Runtime strings and lists:** **a fixed-capacity StateHeap and list slab, mark-compacted at the turn boundary.** This satisfies TigerStyle's "no allocation after init". Refcount/COW is rejected because it needs either an allocator or a free list, and it puts rc traffic on the hot path.
- **D5 `cont()` result:** **a borrowed slice, valid until the next call**, plus a `cont_alloc(gpa)` convenience. This is a breaking change.
- **D6 Zig version:** **0.17.0.**
- **D7 Compiler output:** **`Program` is primary.** `.ink.json` is just a serialization, and the JSON path remains the e2e oracle until P9.
- **D8 Naming (new):** **adopt TigerStyle snake_case for all functions, including the public API** (`cont`, `can_continue`, `current_choices`, `choose_choice_index`, `choose_path_string`, `bind_external_function`, `observe_variable`, `evaluate_function`, `to_json`, `load_json`, `switch_flow`, …). Files are snake_case too (`string_pool.zig`, not `StringPool.zig`). The API is breaking anyway (D5), so rename once, in P6.3. Docs and memory get updated in P9.3.
- **D9 Recursion (new):** **zero recursion in new code**, enforced by a call-graph lint. The front end uses an explicit-stack parser; traversals use post-order or work stacks. The alternative was recursion guarded by a depth assertion. It is simpler to write, but it violates the rule and makes native stack use input-dependent.
- **D10 Dispatch function length (new):** **one documented exception to the 70-line rule** for `vm.run`'s labeled switch. Each prong is at most about 3 lines and delegates to a pure helper, so the function has no logic beyond dispatch. The alternative is a two-level dispatch (opcode category, then helper), which costs an extra indirect branch per instruction.
- **D11 Assertion builds (new):** **ship ReleaseSafe as the default**; ReleaseFast is opt-in for benchmarks. Per §3.2 the hot path only uses `std.debug.assert`.

---

## 6. Phased work breakdown

Every item has **success criteria validated by unit tests**, per the project rule. Every task's implementation notes must contain a back-of-envelope sketch (§3.2). New code must pass the P0.8 lint. Items in the same phase can mostly run in parallel. "Oracle" refers to P0.4.

### Phase 0: Safety net, baseline, tooling

- **P0.1 Zig 0.17 compatibility.** Replace `dupeZ` and bump `build.zig.zon`.
  - ✅ `zig build test` on 0.17.0 passes 549/549.
- **P0.2 Split build steps.** Add `test-runtime`, `test-compiler`, `test-core`, `bench`, `lint`, `fuzz` and `simulate`, plus `-Dtest-filter`. Remove the unused module.
  - ✅ Each step runs on its own, and the totals match the full suite.
- **P0.3 Transcript corpus tool** (`tools/transcript.zig`).
  - Runs every compiled fixture with a deterministic choice policy and writes `*.transcript` files containing text, tags, choices per turn and the final variables.
  - ✅ A test regenerates the transcripts and the diff is empty.
- **P0.4 Differential oracle harness.** Runs old vs new engine (or old vs stored transcripts) turn by turn.
  - ✅ A seeded divergence reports the first differing turn.
- **P0.5 Allocation-counting allocator.**
  - ✅ A self-test passes. The "zero allocation in cont" test against the old runtime is recorded as skipped, with the reason.
- **P0.6 Benchmarks** (`tools/bench.zig`, ReleaseFast).
  - Measures load time, `cont()` steps/s, bytes per instruction/node, peak RSS and compile time on `crime_scene` and a generated large story.
  - ✅ The baseline is committed to `docs/benchmarks.md`.
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
  - Compiler:
    - label names collide globally across knots
    - `temp_names` is never reset
    - INCLUDE is unresolved
    - list auto-numbering is wrong
    - `compile()` ignores errors
- **P0.8 TigerStyle lint tool** (`tools/lint.zig`, `zig build lint`). It checks:
  - function length ≤ 70 lines, with an allowlist entry for `vm.run` (D10)
  - line length ≤ 100 columns
  - no recursion: a call-graph cycle check using `std.zig.Ast` over `src/`, plus a per-directory allowlist so old code can be grandfathered until it is deleted
  - no `usize` struct fields
  - snake_case file names
  - an assertion-density report (asserts per function) that fails new modules averaging below 2
  - ✅ The lint passes on `src/core/` from day one. A tests-for-the-linter suite shows each rule firing on sample inputs.
- **P0.9 Fuzz and simulation harness.**
  - `zig build fuzz` targets: tokenizer, parser, JSON loader, and the save/load round trip.
  - `tools/simulate.zig` is a VOPR-style deterministic simulator. From a seed, it plays every fixture with random choices, random save/load points, random flow switches and random `evaluate_function` calls, running `State.verify()` at every turn.
  - ✅ The harness runs (targeting the old runtime first) and is reproducible by seed.

### Phase 1: Core primitives (`src/core/`)

- **P1.1 `index.zig`.** ✅ Round-trip tests; `to_int(.none)` panics in a safe build (tested via a child process or `std.testing` panic hook); comptime size asserts.
- **P1.2 `limits.zig`.** ✅ Comptime relationship asserts compile; runtime `Limits.verify()` rejects inconsistent options (negative space).
- **P1.3 `string_pool.zig`.** ✅ Deduplication; id 0 is `""`; `find` never inserts; zero allocations during lookup; 100k strings round-trip; an invalid id asserts.
- **P1.4 `extra.zig`.** ✅ Round trip of a struct with u32, enum, packed and trailing-slice fields.
- **P1.5 `bounded_stack.zig` and `work_stack.zig`.** ✅ Overflow returns an error; `truncate` restores the previous length; `verify` catches a corrupted length (negative-space test).
- **P1.6 `tag_set.zig`.** ✅ Set algebra.
- **P1.7 `sizes_test.zig`.** ✅ Size asserts for every core type (`Value` 16 B; `OutputItem` ≤ 12 B; `Frame` ≤ 24 B; `Instruction`, `Node` and `Token` 5 B in SoA).

### Phase 2: Program image and builder

- **P2.1 `Opcode`, `Instruction` and operand encodings,** with typed `instruction_add`. ✅ Encode/decode round trip for every opcode; comptime exhaustiveness.
- **P2.2 `ContainerInfo` SoA and the named table.** ✅ Named lookup compares u32s only; out-of-range lookups assert.
- **P2.3 `ProgramBuilder`** with the fixup list and `finish()`, followed by `Program.verify()`. ✅ Contiguous nested containers; fixups resolve; unresolved targets produce a diagnostic; a corrupted program fails `verify` (negative space).
- **P2.4 Path and hash tables.** ✅ Every container path and `path_hash` in `crime_scene` matches the old runtime's `Container.path` and its `shuffleIndex` seed.
- **P2.5 Globals, lists and externals tables.** ✅ Tests on a small lists fixture.
- **P2.6 `program.dump(writer)`** (iterative). ✅ Snapshot test.

### Phase 3: JSON → Program loader

- **P3.1 Streaming loader** (no `std.json.Value` tree, explicit `WorkStack`). ✅ Every compiled fixture loads. No allocations after `finish()`. Peak memory is below the old loader's. Fuzz target added.
- **P3.2 Load-time path resolution** for every target kind. ✅ A scan asserts that no operand refers to a path string, and `verify` passes.
- **P3.3 Structural parity with the old `Story.containers`.** ✅ Parity on every fixture.

### Phase 4: Runtime state

- **P4.1 `Value` and native op semantics.** ✅ The `evaluation.zig` tests are ported 1:1, plus invalid-operand tests.
- **P4.2 List slab bitsets and all list builtins.** ✅ All list tests ported; display order; empty-list origins.
- **P4.3 StateHeap with mark-compact.** ✅
  - Heap use stays bounded over 10k turns of string concatenation.
  - Live strings survive compaction.
  - `error.HeapLimit` is returned on a true overflow.
  - Debug poisoning catches a stale reference (negative test).
- **P4.4 Flat frames, threads and temps; fork by range copy.** ✅ Callstack tests ported; fork/pop restores state exactly; every limit returns its named error.
- **P4.5 `OutputItem` stream and `string_marks`.** ✅ Every newline/glue/whitespace test passes.
- **P4.6 Choices SoA with tag ranges and the real thread index.** ✅ Choice tag tests.
- **P4.7 Flows.** ✅ Multiflow tests; listing alive flow names works.
- **P4.8 `State.verify()`.** ✅ It catches each seeded corruption: a frame range out of bounds, a dangling `StringReference`, temps outside their frame.

### Phase 5: VM

- **P5.1 Labeled-switch `vm.run` with a step budget.** ✅ Oracle passes on the basic, text and divert subset; budget exhaustion is tested.
- **P5.2 Root-cause and remove the weave heuristics.** Write a minimal reproduction for each case they handle and fix the cause in compiler or VM semantics. ✅ The reproductions pass on the new VM with no heuristic code.
- **P5.3 Variables:** global slots, frame temps, variable pointers with Ink-exact scoping. ✅ Tests plus a scoping regression test.
- **P5.4 Functions, tunnels, threads, externals** (index table, arguments as a stack view, fallbacks). ✅ Ported tests; zero allocations.
- **P5.5 Observers,** queued and batched at the turn end. ✅ Each observer fires once per variable per turn, after output.
- **P5.6 `evaluate_function`** via a snapshot into a shadow state; re-entrant calls are rejected. ✅ The `evaluating_ink_functions_from_game*` tests pass with zero allocations.
- **P5.7 Zero-allocation gate.** ✅ Every fixture runs `cont`, `choose_choice_index` and `evaluate_function` with 0 allocations after init.
- **P5.8 Full oracle parity and simulator.** ✅ Transcripts match on every fixture; all runtime tests ported; `simulate` runs 10k seeds with no verify failure.

### Phase 6: Save/load and public API

- **P6.1 `to_json`** (Ink-compatible, including choices, flows, tags and seed; iterative writer). `State.verify()` runs before saving. ✅ The P0.7 save bugs are fixed and their tests un-skipped.
- **P6.2 `load_json`.** No dangling keys; strings go into StateHeap; `verify()` runs after loading (pair assertion with P6.1). ✅ Save, load, then continue produces the same transcript as an uninterrupted run, at every turn of every fixture; the fuzz target is added.
- **P6.3 Public API (D5, D8).**
  - In-place `story.init(gpa, json, options)`.
  - snake_case methods; `Story.Options{ limits }`; `cont_alloc`.
  - The public `Value` type is used in callbacks.
  - Callbacks come last in each parameter list.
  - ✅ An API test exercises every public method, including every limit error.
- **P6b (stretch, gated by benchmark) Full linearisation.** ✅ Oracle still passes and throughput improves by at least 15%; otherwise the change is dropped.

### Phase 7: Compiler front end

- **P7.1 Mode-aware tokenizer.** ✅ Rewritten tests; every `.ink` fixture tokenizes without `invalid` tokens; the stream ends with `eof` at `source.len`; fuzz target added.
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

- **P8.1 Scoped symbol tables and the iterative resolve pass.** ✅ The same label in two knots resolves correctly; temps are scoped; forward references work; unresolved names produce a diagnostic.
- **P8.2 INCLUDE resolution** (Io-based; bounded include depth and file count; cycle detection). ✅ The include fixtures pass; an include cycle produces a diagnostic.
- **P8.3 Constants and lists** (auto-numbering fixed). ✅ Regression test.
- **P8.4 Lowering to `ProgramBuilder`** (one iterative pass, backpatch stacks, Inklecate-compatible container layout). ✅ All 209 e2e tests pass via compile → Program → new VM.
- **P8.5 `ink_json.serialize`.** ✅ `load(serialize(compile(source)))` equals `compile(source)` (verified pair); the exact-JSON test passes; a sample matches Inklecate output.
- **P8.6 Compiler performance and allocation discipline.** ✅ The benchmark shows at least 2× less memory than baseline. The compile arena is sized from the source length and retries at most `compile_retries_max` times.

### Phase 9: Removal, rule enforcement, docs

- **P9.1 Delete the old runtime.** ✅ Suite green; lint allowlist for runtime removed.
- **P9.2 Delete the old compiler.** ✅ Suite green; lint allowlist emptied; all P0.7 skips are gone.
- **P9.3 Documentation.**
  - Rewrite `docs/Architecture.md`.
  - Update `docs/Guidelines.md`, merging the TigerStyle rules from §3 with the DOD rules (index newtypes, no pointers in persistent data, `string_pool`, `bounded_stack`, size guards, zero-allocation gate, no recursion, limits).
  - Update `docs/ArchitectureAndDevOverview.md` and `docs/RunningYourInk.md` for D5 and D8.
  - Update the project memory and the API conventions.
  - ✅ Doc code samples compile in a doctest step.
- **P9.4 Final benchmark report.**

---

## 7. Dependency graph

```
P0 ─┬─> P1 ─> P2 ─> P3 ─┬─> P4 ─> P5 ─> P6 ─> P9.1
    │                   │                 └─> P6b (optional)
    │                   └─────────────> P8.4 (needs P2 builder)
    └─> P7 (needs P1)  ─────────────> P8 ─> P9.2
P0.8 lint gates every phase. P9.3/P9.4 after P9.1 + P9.2.
```

---

## 8. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Weave heuristics hide real semantic gaps | P5.2 reproductions first; the oracle and simulator catch regressions |
| Save-format compatibility | D2 keeps containers; path table; save/load/continue oracle; fuzzing |
| Mark-compact bugs | Paired `verify` before and after; Debug poisoning; the simulator compacts on every step in Debug |
| Fixed limits too small for real stories | Generous defaults; `Options.limits`; named overflow errors; the benchmark story sets the defaults |
| Non-recursive parser harder to write than recursive descent | Ink weave is level-based; braces and expressions use standard explicit-stack algorithms; the snapshot corpus is built first |
| 70-line limit forces awkward splits | Push ifs up and fors down; one documented exception (D10) |
| Public API rename (D8) breaks users | One breaking release together with D5; a migration table in `RunningYourInk.md` |
| Big-bang risk | Strangler: old and new coexist until P9, every phase merges green |
| Assertion overhead in the hot path | Control/data plane split; `std.debug.assert` only in `vm.run`; verify at turn boundaries (D11) |

---

## 9. Success metrics (final acceptance)

- 100% of behavioural tests pass, plus the oracle, save/load/continue, resilience, snapshot, fuzz and simulation (10k seeds) suites.
- **0 allocations** in `cont`, `choose_choice_index` and `evaluate_function` after init (test-enforced).
- **0 recursion, no function over 70 lines** (except D10), no line over 100 columns, an assertion density of at least 2 per function in `src/`. `zig build lint` passes with an empty allowlist.
- The VM hot path contains no path-string resolution, no string hashing and no `mem.eql` (lint grep gate on `vm.zig`).
- Memory stays bounded over 10k turns (test-enforced).
- Size guards hold: `Value` 16 B; `Instruction`, `Node` and `Token` 5 B SoA.
- Benchmarks: `cont()` throughput at least 3× baseline, load at least 2× faster, compiler peak memory at least 2× lower. These targets will be revised after P0.6.
