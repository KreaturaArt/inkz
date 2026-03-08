---
id: TASK-72
title: >-
  Zero runtime allocation — pre-allocate stacks, indexed visit counts, string
  buffer
status: To Do
assignee: []
created_date: '2026-03-08 13:08'
labels:
  - runtime
  - architecture
  - zero-allocation
dependencies:
  - TASK-71
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
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
<!-- AC:BEGIN -->
- `zig build test` passes all existing tests
- `grep -n "self\.allocator" src/runtime/story.zig` — zero matches inside `step()`, `dispatchObject()`, `handleControlCommand()`, `recordVisitIfNeeded()`
- `grep -n "\.append(self\.allocator" src/runtime/story.zig` — zero matches in hot-path functions
- `visit_counts` and `turn_indices` are `[]u32` / `[]i32` (direct-indexed by container_idx, not StringHashMap)
- `string_eval_buf: [4096]u8` field exists on Story; `end_string` uses it
- `std.mem.concat(self.allocator` no longer appears in `evaluation.zig`
<!-- SECTION:DESCRIPTION:END -->

- [ ] #1 zig build test passes all existing tests
- [ ] #2 No self.allocator calls inside step(), dispatchObject(), handleControlCommand(), recordVisitIfNeeded()
- [ ] #3 evaluation_stack and output_stream use appendAssumeCapacity in hot path
- [ ] #4 visit_counts is []u32 indexed by container_idx (not StringHashMap)
- [ ] #5 turn_indices is []i32 indexed by container_idx (not StringHashMap)
- [ ] #6 string_eval_buf: [4096]u8 field on Story; end_string uses it instead of ArrayList
- [ ] #7 std.mem.concat uses arena allocator in evaluation.zig (not self.allocator)
<!-- AC:END -->
