# TASK-5: Container type

- Status: Done
- Priority: high
- Labels: layer-1, core-types
- Dependencies: —
- Created: 2026-02-23 · Updated: 2026-03-01

## Description

Implement `Container` struct in `src/runtime/container.zig` with `content: []RuntimeObject`, `named_content: std.StringHashMapUnmanaged(*Container)`, `name: ?[]const u8`, `flags: ContainerFlags` (packed struct with visits, turns, count_start_only bits). Arena-allocated; no individual frees.

Tests:
- Create Container with 3 content items; access by index
- Create Container with named sub-container; look up by name
- Flags: flags.visits == true when #f == 1

## Acceptance Criteria
- [x] Container with content array accessible by index
- [x] Named sub-containers looked up by name
- [x] ContainerFlags bits work correctly

## Implementation Notes

Container struct is co-located with RuntimeObject in src/runtime/value.zig (not a separate container.zig) to avoid circular import. Also has path: []const u8, parent: ?*Container, index_in_parent: i32 fields for path resolution. ContainerFlags verified by test 5; Container content/named_content exercised by json_loader tests 14-16.
