# Architecture and development

This is a tour of the code for people who work on inkz. `docs/Architecture.md` has the
diagrams; `docs/Guidelines.md` has the rules every change follows; `docs/RunningYourInk.md`
is the host API guide. Each source file starts with a `//!` comment that says what it does
and which part of `docs/DODMigrationPlan.md` it implements; read those next.

The ```zig blocks in this file are compiled by `zig build doctest`. Excerpts of internal
code are ```text blocks, because the library doesn't export those modules.

## The pieces

| Directory | What it holds |
|---|---|
| `src/core/` | The program image both halves share: `Program`, `ProgramBuilder`, the string pool, index newtypes, limits, `BoundedStack`, ink path strings, .NET's seeded random, and ink's JSON (`ink_json.load`, `ink_json.serialize`). |
| `src/runtime/` | The VM, the state, the Continue loop, save and load, and the public API (`api.zig`). |
| `src/compiler/` | The compiler: parser, object tree, name resolution and lowering to a `Program`. Entry points in `compile.zig`. |
| `src/testing/` | The engine-neutral test layer: ground truth, transcripts, the oracle and divergence ledger, end-to-end tests, the simulator and the zero-allocation gate. |
| `tools/` | Lint, doctest, snapshot files, ground-truth file checks, the death-test runner, and the C# reference harness (`tools/ink_harness/`). |

`src/root.zig` is the library module, imported as `inkz`. It re-exports the runtime API at
the top level (`inkz.Story`, `inkz.Value`, `inkz.Choice`, `inkz.Limits`, ...) and the
modules `inkz.compiler`, `inkz.runtime`, `inkz.core`, `inkz.ink_json` and the type
`inkz.Program`.

## One image, two producers

Everything the runtime runs is a `Program` (`src/core/program.zig`): an immutable,
pre-resolved story image. Two producers make one, and both drive the same
`ProgramBuilder`:

- the JSON loader, `ink_json.load(gpa, json)`, from ink's compiled `.ink.json`;
- the compiler, `inkz.compiler.compile_source(gpa, source)` or `compile_file`, from `.ink`.

`ink_json.serialize` writes a `Program` back as inklecate's JSON. The structural gate
(`src/testing/structure_gate.zig`) checks that the compiler's JSON equals inklecate's for
every ground-truth story, and that `load(serialize(compile(source)))` equals
`compile(source)` field by field.

A `Program` is struct-of-arrays data addressed by `u32` index newtypes, with no pointers:

- **Instructions:** a one-byte opcode plus a 32-bit operand, 5 bytes, in two arrays. One ink
  content item is exactly one instruction. Operands too wide for 32 bits (a divert's target
  and flags, a choice point) live in the `extra` word table and the operand is their index.
- **Containers:** ink's unit of addressing. Each one is a contiguous range of the one
  instruction array, plus its parent, depth, name, path, counting flags and a range of the
  `named` table (knots, stitches, labelled gathers). A nested container appears as an
  `enter_container` instruction at its position in the parent.
- **Strings:** one frozen `StringPool`; instructions hold `StringId`s.
- **Globals, list origins, list items, externals:** small tables indexed by their newtypes.

Every target is resolved to a container index or a `{container, index}` pair when the
program is built, so the VM never sees a path string. `Program.verify()` runs after every
build and load.

This dump shows the layout. `inkz.core.program_dump.dump` lists any program:

```zig
var program = try inkz.compiler.compile_source(gpa, "Hello, world!\n");
defer program.deinit(gpa);

var listing: std.Io.Writer.Allocating = .init(gpa);
defer listing.deinit();
try inkz.core.program_dump.dump(&program, &listing.writer);
std.debug.print("{s}", .{listing.written()});

const json = try inkz.compiler.compile_to_json(gpa, "Hello, world!\n");
defer gpa.free(json);
std.debug.print("{s}\n", .{json});
```

## The compiler

The compiler is a faithful, non-recursive port of ink's `InkParser` and `ParsedHierarchy`
(C#, ink v1.2.1). Each stage is a file or a few; their `//!` comments name the C# classes
they follow.

1. **Source space** (`source_space.zig`): every file of a compilation, with comments removed
   (ink's `CommentEliminator`), laid end to end in one buffer. `INCLUDE`d files are appended
   as they are found. Token and node indices are therefore global, and a file table maps
   offsets back to `file:line:column`.
2. **Parser** (`core.zig`, `grammar*.zig`): ink's backtracking rules, run on an explicit
   stack instead of the native one. A rule is a step function with numbered phases. Each
   step returns an `Action`: `call` another rule, `peek` at one, `succeed`, `fail`, or run
   `again`. A call pushes a frame that holds a checkpoint (input position, token, node and
   scratch counts); a failed rule restores it. That gives StringParser's
   `BeginRule`/`FailRule`/`SucceedRule`, and so `OneOf`, `Optional` and `Interleave`. The
   frame stack is bounded by `parse_depth_max`, and a gas counter bounds the steps by the
   input length. Like ink's StringParser, the rules read characters themselves; a token is
   the `start` and `end` of a name or a text run they record (`lexical.zig` holds the
   comment removal and ink's identifier characters).
3. **Syntax tree** (`ast.zig`): a node is a one-byte tag and one `u32` word (5 bytes, two
   arrays). Children are contiguous; a parent's word is the index of its first child.
4. **Object tree** (`sema.zig`, `sema_build.zig`, `sema_includes.zig`): ink's parsed
   hierarchy, built the way ink's constructors build it. A flow's statements are split into
   its weave and its sub-flows; a weave nests its choices and gathers by indentation.
5. **Resolution** (`resolve*.zig`): ink's two phases. While generating, in tree order,
   declarations are registered and each divert's target is resolved. Then
   `ResolveReferences` runs children first. Naming collisions are checked here.
6. **Lowering** (`lower*.zig`): each object's `GenerateRuntimeObject` into an IR of ink's
   runtime container tree (`lower_ir.zig`), then ink's `ExportRuntime` steps: the
   `global decl` container, count flags, `FlattenContainersIn`, runtime paths, termination
   checks, and emission through `ProgramBuilder` (`lower_emit.zig`).

Every walk uses an explicit stack or a post-order layout. The object tree, the resolution
and the syntax are freed before layout and emission, which keeps peak memory low.

A rule from `grammar_weave.zig`, abridged, shows the shape of the parser:

```text
pub fn choice(machine: *Machine, frame: *Frame) Error!Action {
    switch (frame.phase) {
        0 => {
            // Bullets, an optional (label), then the first condition.
            ...
            frame.phase = 1;
            return .{ .call = .choice_single_condition };
        },
        1 => return choice_conditions(machine, frame),
        ...
        3 => {
            // machine.outcome says whether the rule called in phase 2 matched.
            if (machine.outcome == .succeeded) frame.locals[2] |= choice_option;
            frame.phase = 4;
            return .{ .call = .mixed_text_and_logic };
        },
        ...
    }
}
```

## The runtime

`Story` (`src/runtime/story.zig`) is a borrowed `*const Program`, one `State`, and ink's
Continue loop. The public `inkz.Story` (`api.zig`) wraps it with the host calls and the
borrowed-view checks.

- **State** (`state.zig`) is carved out of one allocation of exactly
  `Limits.bytes_total()` bytes, made in `init`. Nothing allocates afterwards; the
  zero-allocation gate checks this on every ground-truth case. The live flow (evaluation
  stack, call stack, output, choices) is separate from what all flows share (globals, visit
  counts, turn indices, the random state, the heap, diagnostics).
- **Values** (`value.zig`) are 12 bytes: `i32` with wrapping arithmetic and `f32`, as in C#
  ink. Strings are references into the program's pool or the state's heap; lists are
  references into the list slab.
- **The VM** (`vm.zig`) is ink's `Step`, `NextContent` and `PerformLogicAndFlowControl`
  over the flat program. `step` runs one instruction; `run` steps until the output changes,
  a choice appears, the flow ends, or the step budget runs out. The semantics of each
  instruction are in `ops.zig` (variables, strings, tags, choices, randomness) and
  `native.zig` (ink's operators).
- **The Continue loop** (`story.zig`, `lookahead.zig`) is ink's `ContinueInternal`. When the
  output ends in a newline it takes a snapshot of the live flow and starts an undo log of
  shared values. If new text or tags then extend the line, it restores the snapshot and
  returns the line. That is how `cont()` returns one line and still joins glue.
- **The heap** (`heap.zig`) holds runtime strings and lists in fixed buffers, reclaimed by
  sliding mark-compact only when an allocation doesn't fit.
- **Flows** (`flows.zig`) park the used part of each live buffer in a bounded region on a
  switch, so a switch costs a copy of what is used, not of the limits.
- **Saves** (`save.zig`, `load.zig`, `json_tree.zig`) stream ink's save format v10 with no
  allocation, and load into fixed scratch, validating the whole save before touching the
  state.

### What changed for hosts

The rewrite changed the host API in three ways (plan decisions D5, D8, D12):

- `cont()` returns a `Borrowed([]const u8)` view into the story's memory, valid until the
  next mutating call; `cont_alloc(gpa)` returns a copy. In safety-checked builds, `.get()`
  on a stale view fails an assertion.
- All public names are snake_case: `can_continue`, `choose_choice_index`, `get_variable`.
- `cont()` is line-based with ink's newline lookahead; `continue_maximally(writer)` plays
  until the story can't continue, which is what the old `cont()` did.

`docs/RunningYourInk.md` ends with the full table from old names to new ones.

## Working on inkz

Use the pinned toolchain through mise: `mise exec -- zig build <step>`.

| Step | What it does |
|---|---|
| `zig build test` | Every suite below, the death tests and the doctests. |
| `zig build test-runtime`, `test-compiler`, `test-core`, `test-tools` | One suite. `-Dtest-filter=<text>` narrows it. |
| `zig build test-death` | Cases that must panic, one child process each. |
| `zig build doctest` | Compiles the ```zig blocks of the docs against the library. |
| `zig build lint` | The TigerStyle checks (see `docs/Guidelines.md`). |
| `zig build fuzz` | One fuzz target per pipeline stage, on its corpus; add `--fuzz` (and `-Doptimize=ReleaseSafe`) to fuzz. See `docs/fuzzing.md`. |
| `zig build simulate` | Plays every ground-truth case with seeded random choices, saves, loads and flow switches. |
| `zig build transcripts` | Regenerates `test/transcripts/`. |
| `zig build replay` | Installs `replay_case`, which replays one case and prints its transcript. |
| `zig build bench` | Benchmarks in ReleaseSafe and ReleaseFast; writes `docs/benchmarks.md`. |
| `zig build bench-io` | Program load and store, ink's JSON against the binary image, in ReleaseSafe and ReleaseFast; appends to `bench/load_store.jsonl` (see `docs/benchmarks.md`). |
| `zig build bench-profile` | Time per pipeline stage (profile zones, ReleaseFast): prints each workload's zones and the worst zones of one pass; appends to `bench/profile.jsonl`. `zig build test-profile` checks the zones. |

### Ground truth

Correct means "what ink v1.2.1 does on .NET 8". The C# harness in `tools/ink_harness/` builds
ink's own compiler and runtime from a pinned commit and writes the expected outputs, saves
and random sequences into `test/ground_truth/`, with a provenance header. It runs through
mise (`mise run reference:setup`, `mise run reference:expected`) and is never part of
`zig build`, so the Zig suite doesn't need .NET.

Tests describe host actions once, as `.actions` lines, and replay them on the engine
(`src/testing/transcript.zig`). The oracle compares the result with ink's transcript; every
known difference must be listed, with a reason, in `test/divergence_ledger.zon`, and an
entry whose case no longer differs fails too.

### Debugging tips

- `inkz.core.program_dump.dump` (above) lists a program's containers and instructions in
  layout order.
- `inkz.compiler.compile_to_json` shows what the compiler made, in a form you can compare
  with inklecate's output.
- `replay_case <case id>` replays a ground-truth case in its own process; the
  simulator prints the exact command that reproduces each failure it finds.
- `State.check()` and `Program.check()` return a named `Fault` for the first broken
  invariant. `verify()` asserts on it at the boundaries: when a program is built or loaded,
  when the state is reset, saved or loaded, around lookahead snapshots and flow switches,
  and around heap compaction.
