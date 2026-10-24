# TASK-72: >- Zero runtime allocation — pre-allocate stacks, indexed visit counts, string buffer

- Status: Done
- Priority: high
- Labels: runtime, architecture, zero-allocation
- Dependencies: TASK-71
- Created: 2026-03-08 · Updated: 2026-03-08

## Description

Eliminate all allocator calls inside `step()`, `cont()`, and functions called from the hot evaluation path. All dynamic storage is pre-allocated at `Story.initFromJson()` time.

**Depends on TASK-71** (DOP AST flat container array must be done first — visit counts switch to container-index arrays).

## Changes required

### `src/runtime/story.zig`

#### Pre-allocate ArrayLists at init
After building AST in `initFromJson()`:
```zig
try self.state.evaluation_stack.ensureTotalCapacity(self.allocator, 256);
try self.state.output_stream.ensureTotalCapacity(self.allocator, 1024);
try self.state.current_choices.ensureTotalCapacity(self.allocator, 32);
try self.current_tags.ensureTotalCapacity(self.allocator, 16);
```

Switch all hot-path calls: `append(allocator, x)` → `appendAssumeCapacity(x)` in:
- `dispatchObject` (all arms: string, int, float, bool, glue, void, divert_target, variable_pointer, list)
- `handleControlCommand` (eval_start arm pushes to output_stream; begin_string; etc.)
- `runStepLoop` indirectly

#### Direct-indexed visit counts
Replace `StoryState.visit_counts: StringHashMapUnmanaged(u32)` and `turn_indices: StringHashMapUnmanaged(i32)` with:
```zig
// In Story struct (arena-owned, indexed by container_idx):
visit_counts: []u32,   // pre-zeroed
turn_indices: []i32,   // pre-set to -1
```
Allocated at init:
```zig
self.visit_counts = try self.arena.allocator().alloc(u32, self.containers.len);
@memset(self.visit_counts, 0);
self.turn_indices = try self.arena.allocator().alloc(i32, self.containers.len);
@memset(mem.sliceAsBytes(self.turn_indices), 0xFF); // sets all i32 to -1
```

`recordVisitIfNeeded(container_idx: u32)`:
```zig
if (c.flags.visits_should_be_counted)
    self.visit_counts[container_idx] += 1;          // array write, zero alloc
if (c.flags.turn_index_should_be_counted)
    self.turn_indices[container_idx] = self.state.current_turn_index;
```

`visitCountAtPathString(path)`: `self.visit_counts[self.path_to_idx.get(path) orelse return 0]`
`turnsSinceForContainer(container_idx)`: `self.turn_indices[container_idx]`

#### String eval buffer
Add `string_eval_buf: [4096]u8` field to `Story`.

Replace `end_string` handler (currently allocates `ArrayList(u8)` + `appendSlice(alloc, ...)`):
```zig
var len: usize = 0;
for (self.state.output_stream.items[start + 1 ..]) |it| {
    if (it == .string) {
        @memcpy(self.string_eval_buf[len..][0..it.string.len], it.string);
        len += it.string.len;
    }
}
self.state.output_stream.shrinkRetainingCapacity(start);
const s = try self.arena.allocator().dupe(u8, self.string_eval_buf[0..len]);
self.state.evaluation_stack.appendAssumeCapacity(.{ .string = s });
```

#### Variable assignment — guarantee no HashMap growth
After global decl init loop completes, call:
```zig
// variables_state.globals already contains all declared vars
// ensureTotalCapacity so put() on existing keys never grows:
// (This is a no-op if capacity is already sufficient)
```
Because ink's `VAR=` re-assignment only writes to already-declared keys, `put()` on an existing key never triggers resize. Verify by assertion or comment.

### `src/runtime/evaluation.zig`

#### String `+` operator
Change `std.mem.concat(self.allocator, ...)` → `std.mem.concat(self.arena.allocator(), ...)`.

Concat results live in the arena for the story lifetime (correct: may be stored in variables).

### `src/runtime/state.zig`
Remove `visit_counts` and `turn_indices` fields (now live in `Story`, indexed by container_idx). Update `init()` and `deinit()` accordingly.

## What remains acceptable (not hot-path)
- List operations (`list_range`, `list_all`, `list_invert`, etc.): use `arena.create(InkList)` — arena-allocated, bounded by story content, NOT `self.allocator`. Acceptable.
- `collectOutput()` builds output `[]u8`: uses `self.allocator`, called once per `cont()`, not inside `step()`.
- Save/load (`toJson`, `loadJson`): uses `self.allocator`, not in hot path.

## Acceptance Criteria
- `zig build test` passes all existing tests
- `grep -n "self\.allocator" src/runtime/story.zig` — zero matches inside `step()`, `dispatchObject()`, `handleControlCommand()`, `recordVisitIfNeeded()`
- `grep -n "\.append(self\.allocator" src/runtime/story.zig` — zero matches in hot-path functions
- `visit_counts` and `turn_indices` are `[]u32` / `[]i32` (direct-indexed by container_idx, not StringHashMap)
- `string_eval_buf: [4096]u8` field exists on Story; `end_string` uses it
- `std.mem.concat(self.allocator` no longer appears in `evaluation.zig`

- [ ] zig build test passes all existing tests
- [ ] No self.allocator calls inside step(), dispatchObject(), handleControlCommand(), recordVisitIfNeeded()
- [ ] evaluation_stack and output_stream use appendAssumeCapacity in hot path
- [ ] visit_counts is []u32 indexed by container_idx (not StringHashMap)
- [ ] turn_indices is []i32 indexed by container_idx (not StringHashMap)
- [ ] string_eval_buf: [4096]u8 field on Story; end_string uses it instead of ArrayList
- [ ] std.mem.concat uses arena allocator in evaluation.zig (not self.allocator)

## Final Summary

## Zero Runtime Allocation — Complete

All allocator calls eliminated from the hot execution path (`step()`, `dispatchObject()`, `handleControlCommand()`, `recordVisitIfNeeded()`).

### Changes made:

**state.zig**: Removed `visit_counts`/`turn_indices` StringHashMaps from `StoryState`.

**story.zig**:
- Added `visit_counts: []u32`, `turn_indices: []i32`, `string_eval_buf: [4096]u8` fields
- Pre-allocate all ArrayLists at `initFromJson()` (256 eval, 1024 output, 32 choices, 16 tags, 256 globals)
- `recordVisitIfNeeded()` uses direct array writes (`self.visit_counts[idx] += 1`)
- `end_string`/`end_tag` use `string_eval_buf` instead of ArrayList
- String concat uses `self.arena.allocator()` instead of `self.allocator`
- All hot-path `append(allocator, x)` → `appendAssumeCapacity(x)`
- Variable assignment uses `setAssumeCapacity` (no allocator in dispatchObject)
- `loadStateFromJson` ensures 32 spare temp-var slots per loaded call stack element

**variables.zig**: Added `setAssumeCapacity`, updated `clone()` to pre-allocate count+32 slots.

**callstack.zig**: `Thread.init()` and `CallStack.push()` pre-allocate 32 temp-var slots per element.

**evaluation.zig**: All `stack.append(allocator, x)` → `stack.appendAssumeCapacity(x)` in `callNativeFunction`.

All 240 tests pass.
