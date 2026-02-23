---
id: TASK-6
title: Path type
status: To Do
assignee: []
created_date: '2026-02-23 19:18'
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
- [ ] #1 Path.fromString parses absolute and relative paths correctly
- [ ] #2 Parent component parsed from ^
- [ ] #3 Round-trip toString matches input
<!-- AC:END -->
