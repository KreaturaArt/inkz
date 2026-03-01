---
id: TASK-5
title: Container type
status: Done
assignee: []
created_date: '2026-02-23 19:18'
updated_date: '2026-03-01 17:31'
labels:
  - layer-1
  - core-types
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement `Container` struct in `src/runtime/container.zig` with `content: []RuntimeObject`, `named_content: std.StringHashMapUnmanaged(*Container)`, `name: ?[]const u8`, `flags: ContainerFlags` (packed struct with visits, turns, count_start_only bits). Arena-allocated; no individual frees.

Tests:
- Create Container with 3 content items; access by index
- Create Container with named sub-container; look up by name
- Flags: flags.visits == true when #f == 1
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Container with content array accessible by index
- [x] #2 Named sub-containers looked up by name
- [x] #3 ContainerFlags bits work correctly
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Container struct is co-located with RuntimeObject in src/runtime/value.zig (not a separate container.zig) to avoid circular import. Also has path: []const u8, parent: ?*Container, index_in_parent: i32 fields for path resolution. ContainerFlags verified by test 5; Container content/named_content exercised by json_loader tests 14-16.
<!-- SECTION:NOTES:END -->
