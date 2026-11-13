# Engineering guidelines

These rules apply to all code in inkz. They are TigerStyle (`TIGER_STYLE.md`) as plan §3
applies it, plus the data-oriented rules the rewrite introduced. The last column of each
table says how a rule is enforced; "lint" means `zig build lint` (`tools/lint.zig`), which
checks `src/` and `tools/` with no allowlist.

The ```zig blocks in this file are compiled, and their tests run, in `zig build doctest`.

## Safety

| Rule | What it means here | Enforced by |
|---|---|---|
| No recursion | Parser, sema, lowering, JSON load and write, save and load, path resolution and heap compaction use explicit bounded stacks or post-order layouts. The VM is a flat loop; ink calls push frames onto a bounded stack, never onto the native stack. | Lint: a name-based call-graph cycle check. A false positive needs `// lint: allow recursion: <reason>` above the function. |
| A limit on everything | Every buffer and every loop has a bound. Runtime bounds are in `Limits` (`src/core/limits.zig`), overridable through `Story.Options.limits`; compiler bounds are in `CompilerLimits`. Exceeding one returns a named error (`error.FrameLimit`, `error.HeapLimit`, `error.StepLimit`, ...). | Tests per limit |
| A total memory budget | `Limits.bytes_total(shape)` is the exact size of the one allocation `Story.init` makes. | A test pins the default budget; the init allocation equals it. |
| Explicitly sized types | `u32` for indices and counts. `usize` appears only at slice-indexing boundaries, through `@as(usize, index)` or `@intCast`. | Lint: a `usize` struct field is an error. |
| Real assertions | Preconditions on arguments, postconditions on results, invariants: facts the code relies on that could be false. Not the type restated, a value just assigned, or the same check in every function. Split compound assertions; use `if (a) assert(b)` for implications; assert the positive and the negative space. | Lint: library code (src/core, src/runtime, src/compiler) averages at least one per function per file (`// lint: allow assertion_density: <reason>` to suppress); tests and tools are exempt. |
| Pair assertions | A structure with invariants has `check() Fault` (a named enum, `.ok` when valid) and `verify()`, which panics unless `check()` is `.ok`, in every build mode. Tests corrupt a structure and inspect `check()`; code calls `verify()` at boundaries. | Tests; death tests (`zig build test-death`) for real panics |
| Compile-time relationship asserts | `@sizeOf(Value) == 12`, an opcode fits a byte, limits fit their index types. | Compile time |
| Static allocation | The runtime allocates only in `Story.init` (and `init_from_json`), never afterwards, including in `load_json`. The compiler allocates in its compile phase, sized from the source length, with a bounded retry. | The zero-allocation gate (below) |
| Smallest scope, no duplicated state | No cached copies of state that can go stale. | Review |
| Functions of at most 70 lines | Push `if`s up and `for`s down: parents own control flow, helpers stay pure. | Lint (`// lint: allow function_length: <reason>` for the documented exceptions) |
| All errors handled | No `catch unreachable` on operating errors; no swallowed errors; explicit error sets on public functions where they are known. | Lint and review |
| Callbacks don't reach into state | Observers are queued during `cont()` and called once per variable at its end. Callbacks get values, never pointers into state, and a mutating call from a callback returns `error.Reentrant`. | Tests |

## Data-oriented rules

### Index newtypes, no pointers in persistent data

Anything that persists (the program, the state, the compiler's trees) refers to other data
by typed `u32` index, never by pointer. `inkz.core.index.Index(name)` makes a distinct type,
so a container index can't be passed where a string id is expected. `.none` means "no
index" and is never a valid position; `to_int` asserts on it.

Without pointers, a structure can be copied with `@memcpy` (lookahead snapshots, parked
flows), relocated (heap compaction), saved and checked by `check()`.

```zig
const std = @import("std");
const inkz = @import("inkz");

const ItemIndex = inkz.core.index.Index("item");
const NameIndex = inkz.core.index.Index("name");

test "index newtypes are distinct one-word types" {
    const item = ItemIndex.from_int(3);
    try std.testing.expectEqual(@as(u32, 3), item.to_int());
    try std.testing.expect(ItemIndex.none.is_none());
    try std.testing.expect(ItemIndex != NameIndex); // Passing one for the other doesn't compile.
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(ItemIndex));
}
```

### Strings go through `string_pool`

Strings in a program are interned once into a `StringPool` while it is built, then frozen
into an exact-size `FrozenStringPool`. Code holds `StringId`s and compares them as integers;
id 0 is the empty string. Runtime strings live in the state's fixed heap, referenced by
`StringReference`, whose high bit selects the program pool or the heap.

```zig
const std = @import("std");
const inkz = @import("inkz");

test "interning gives one id per distinct string" {
    const gpa = std.testing.allocator;
    var pool = try inkz.core.string_pool.StringPool.init(gpa);
    const knot = try pool.intern(gpa, "knot");
    try std.testing.expectEqual(knot, try pool.intern(gpa, "knot"));

    var frozen = try pool.freeze(gpa); // `pool` is invalid from here on.
    defer frozen.deinit(gpa);
    try std.testing.expectEqualStrings("knot", frozen.get(knot));
    try std.testing.expectEqual(knot, frozen.find("knot").?);
    try std.testing.expect(frozen.find("stitch") == null);
}
```

### Growth goes through `bounded_stack`

A `BoundedStack(T)` is a stack over a fixed buffer. A push onto a full stack returns
`error.Overflow`, which the caller turns into its named limit error. There is no
`appendAssumeCapacity` on runtime data.

```zig
const std = @import("std");
const inkz = @import("inkz");

const Frame = struct { container: u32, index: u32 };

fn push_frame(stack: *inkz.core.bounded_stack.BoundedStack(Frame), frame: Frame) !void {
    stack.push(frame) catch return error.FrameLimit;
}

test "a full stack is an error, not undefined behaviour" {
    var buffer: [2]Frame = undefined;
    var stack: inkz.core.bounded_stack.BoundedStack(Frame) = .init(&buffer);
    try push_frame(&stack, .{ .container = 0, .index = 0 });
    try push_frame(&stack, .{ .container = 1, .index = 4 });
    try std.testing.expectError(error.FrameLimit, push_frame(&stack, .{ .container = 2, .index = 0 }));
    try std.testing.expectEqual(@as(u32, 1), stack.pop().?.container);
}
```

### Struct of arrays and size guards

Hot tables are `std.MultiArrayList`s: instructions (opcode and operand), containers, syntax
nodes and tokens. A field added in passing changes memory use for every element, so each
hot type's size is pinned: by a `comptime assert` next to the type, by
`src/core/sizes_test.zig`, and by `Limits.element_bytes`, which `bytes_total` uses. A test
that fails here means the budget changed; update it on purpose, not to make the test pass.

```zig
const std = @import("std");
const inkz = @import("inkz");

test "a value is 12 bytes" {
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(inkz.runtime.value.Value));
}
```

### The zero-allocation gate

After `Story.init`, the runtime allocates nothing. `src/testing/zero_allocation.zig` checks
it two ways: no field of `Story` or `State` is an allocator (a compile-time check), and
every ground-truth case runs `cont`, `choose_choice_index`, `set_variable` and
`switch_flow` with a counting allocator behind `init`, whose count must not move. Separate
tests do the same for `evaluate_function` and `load_json`. Code on these paths uses the
state's fixed buffers and heap.

### Borrowed views and their lifetime

Public calls return views into the story's memory instead of copies (`Borrowed(T)`): line
text, choice text and tags, variable values, the flow name, `evaluate_function`'s result. A
view is valid until the next mutating call on that story. In builds with runtime safety,
each view carries the story's generation counter, and `.get()` asserts that it hasn't
changed. Callback arguments (strings in an observer, external function arguments, tag text
in a sink) are valid only during the callback.

```zig
const line = try story.cont();
const text = line.get(); // Valid until the next mutating call.
const copy = try gpa.dupe(u8, text);
defer gpa.free(copy);
if (story.can_continue()) _ = try story.cont(); // `line` and `text` are stale from here.
```

## Performance

- Write a back-of-envelope sketch first: bytes and cache lines touched per operation. An
  instruction is 5 bytes, a value 12, a frame 24.
- The control plane (loading, verification, save and load, the compiler) asserts heavily.
  The data plane (`vm.run`) uses `std.debug.assert`, which stays on in ReleaseSafe, the
  shipped mode, and runs whole-structure checks at batch boundaries, not per instruction.
- The unit of work is one `cont()`: text is assembled and observers are notified once per
  call. The heap is compacted only when an allocation fails.
- The VM's hot path never resolves a path, hashes or compares strings (lint: `hot_path`).
- Measure in ReleaseSafe and ReleaseFast (`zig build bench`).

## Naming and layout

- snake_case for files, functions and variables, the public API included (lint checks file
  names). Types are TitleCase.
- No abbreviations: `container_index`, not `cidx`; `source`/`target`, not `src`/`dest`.
- Units and qualifiers last: `frames_max`, `frames_count`, `heap_bytes_max`. Keep index,
  count and size distinct in names.
- Struct order: fields, then types, then methods.
- Structs over 16 bytes are passed as `*const`. Large structs (`Story`, `State`) are
  initialised in place: `story.init(gpa, &program, options)`.
- A function with two arguments of the same type takes an options struct.
- Comments are sentences that say why. Every test starts with a comment giving its goal and
  method.
- `zig fmt`, 4 spaces, at most 100 columns (lint), braces on every multi-line `if`.
- No dependencies and Zig-only tooling: tools live in `tools/*.zig` and run as build steps.
  The one exception is the C# reference harness, which only generates checked-in data.

## Zig specifics

### `Io`

Pass `io: std.Io` to every function that needs it. Tests use `std.testing.io`. A program
gets one from `std.process.Init`:

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const json = try std.Io.Dir.cwd().readFileAlloc(io, "story.ink.json", init.gpa, .limited(1 << 24));
    defer init.gpa.free(json);
}
```

### Labeled switches for scanners and dispatch

Scanners are labeled-switch state machines: each prong does one small thing and continues
with the next state, so the loop compiles to direct jumps. Plan D10 allows the VM's dispatch
to exceed 70 lines for this, if each prong stays a few lines and delegates to a helper; it
currently fits in 70 lines without the exception.

```zig
const std = @import("std");

/// The length of the identifier at the start of `text`.
fn identifier_length(text: []const u8) u32 {
    var at: u32 = 0;
    scan: switch (if (text.len > 0) text[0] else 0) {
        'a'...'z', 'A'...'Z', '_', '0'...'9' => {
            at += 1;
            continue :scan if (at < text.len) text[at] else 0;
        },
        else => {},
    }
    return at;
}

test "the scanner stops at the first non-identifier character" {
    try std.testing.expectEqual(@as(u32, 5), identifier_length("knot_.x"));
    try std.testing.expectEqual(@as(u32, 0), identifier_length(""));
}
```

### Trees

Syntax trees are struct-of-arrays nodes (a one-byte tag and a `u32` word). A node's
children are one contiguous run, and the parent stores the index of the first; nothing is a
pointer. Traversals use an explicit stack.
