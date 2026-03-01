---
id: TASK-6
title: Path type
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
Implement `PathComponent = union(enum){ name: []const u8, index: u32, parent }` and `Path = struct{ components: []PathComponent, is_relative: bool }` in `src/runtime/path.zig`. `Path.fromString(s)` parses dot-separated paths.

Tests:
- Path.fromString("0.g-0") → [{index:0}, {name:"g-0"}], absolute
- Path.fromString(".^.1") → [{parent}, {index:1}], relative
- Path.fromString("f") → [{name:"f"}], absolute
- Round-trip: path.toString(alloc) matches input
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Path.fromString parses absolute and relative paths correctly
- [x] #2 Parent component parsed from ^
- [x] #3 Round-trip toString matches input
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented in src/runtime/path.zig. toString uses a stack-allocated ArrayList to avoid std.ArrayList.writer() (removed in 0.16-dev). Verified by tests 6-10 (5 Path tests all pass).
<!-- SECTION:NOTES:END -->
