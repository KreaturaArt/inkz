# TASK-71: DOP AST — flat container array, index-based addressing

- Status: Done
- Priority: high
- Labels: runtime, architecture, dop
- Dependencies: —
- Created: 2026-03-08 · Updated: 2026-03-08

## Description

Replace the current scattered `arena.create(Container)` allocation with a flat pre-allocated `[]Container` array. Address containers by `u32` index throughout the runtime instead of raw pointers.

## Changes required

### `src/runtime/value.zig`
- Add `pub const null_container_idx: u32 = std.math.maxInt(u32);`
- Add `pub const NamedEntry = struct { name: []const u8, container_idx: u32 };`
- Remove `Container.parent: ?*Container` → add `parent_idx: u32 = null_container_idx`
- Remove `Container.named_content: StringHashMapUnmanaged(*Container)` → add `first_named: u32 = 0` + `named_len: u32 = 0` (indices into a global NamedEntry array)
- Change `RuntimeObject.container: *Container` → `container: u32`

### `src/runtime/pointer.zig`
- Change `Pointer.container: ?*Container` → `container_idx: u32`
- `null_value` uses `null_container_idx` sentinel
- `resolve()` takes `containers: []const Container` parameter (no `?*Container` deref)
- Update `isNull()` to check `container_idx == null_container_idx`

### `src/runtime/json_loader.zig`
Two-pass loader:
- **Pass 1** `countContainers(json_val)` → `u32`: recursively count all containers in the JSON tree
- **Pass 2** `fillContainers(arena, json_val, containers, named_entries, ...)`: fill pre-allocated slices with depth-first index assignment (root = 0)
- `LoadedStory` returns `containers: []Container` + `named_entries: []NamedEntry` (replaces `root: *Container`)

### `src/runtime/story.zig`
- Replace `root: *Container` with `containers: []Container` (root is `containers[0]`)
- Add `named_entries: []NamedEntry` field
- Add `path_to_idx: std.StringHashMapUnmanaged(u32)` built at init (for save/load container lookup)
- Add helper `fn containerAt(self, idx: u32) *Container` and `fn namedLookup(self, container_idx, name) ?u32`
- Update all `ptr.container.?` → `self.containerAt(ptr.container_idx)`
- Update `ptr.container.?.parent` → `self.containerAt(self.containerAt(ptr.container_idx).parent_idx)`
- Update `resolvePath` — parent traversal uses `.parent_idx`, named lookup uses `namedLookup()`
- Update `findContainerByPath` to use `path_to_idx` map (O(1), no tree walk)
- Update `writePointerJson` to use `self.containerAt(ptr.container_idx).path`
- Update `dispatchObject(.container)` → uses `u32` index
- Update `recordVisitIfNeeded` to accept `u32` container_idx
- Update `chooseChoiceIndex`, `resolvePath`, `makeChoice` to pass container indices

### `src/runtime/state.zig`
- Remove `visit_counts: StringHashMapUnmanaged(u32)` and `turn_indices: StringHashMapUnmanaged(i32)` (moved to Story fields in TASK-ZERO)
- Update Pointer usage throughout

### `src/runtime/callstack.zig`
- Update `Element.current_pointer: Pointer` (compiles after Pointer type change)
- Update all Pointer construction/access patterns

### `src/runtime/evaluation.zig`
- Update any code that uses `RuntimeObject.container` (was `*Container`, now `u32`)
- Pass `containers: []const Container` where needed for container resolution

## Acceptance Criteria
- `zig build test` passes all existing tests (currently 239)
- No `arena.create(Container)` calls remain in `json_loader.zig`
- `Pointer.container_idx` is `u32` (grep confirms, no `?*Container` in pointer.zig)
- `RuntimeObject.container` is `u32`
- `Container.parent_idx` is `u32` (no `?*Container` parent field)

- [x] zig build test passes all existing tests
- [x] No arena.create(Container) in json_loader.zig
- [x] Pointer.container_idx is u32 — no ?*Container in pointer.zig
- [x] RuntimeObject.container is u32 (not *Container)
- [x] Container.parent_idx is u32 (no ?*Container parent field)
- [x] namedLookup() does linear scan over []NamedEntry (no HashMap per container)

## Final Summary

Implemented DOP AST flat container array across the runtime:\n- `value.zig`: Added `null_container_idx`, `NamedEntry`; replaced `Container.parent`/`named_content` with `parent_idx`/`first_named`/`named_len`; changed `RuntimeObject.container` from `*Container` to `u32`\n- `pointer.zig`: Changed `Pointer.container` to `container_idx: u32`; `resolve()` now takes `[]const Container`\n- `json_loader.zig`: Rewrote loader as single-pass `buildContainer` building into flat `ArrayList(Container)` and `ArrayList(NamedEntry)`; `LoadedStory` now returns `containers: []Container` + `named_entries: []NamedEntry`\n- `story.zig`: Added `containers`, `named_entries`, `path_to_idx` fields; added `containerAt()` and `namedLookup()` helpers; updated all container access, `resolvePath`, `findContainerByPath`, `recordVisitIfNeeded`, `processChoicePoint`, `step`, `trimContainerEndIfNeeded`, `tagsLeadingContent`, `writePointerJson`\nAll 240 tests pass."
