---
id: TASK-5
title: Container type
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
Implement `Container` struct in `src/runtime/container.zig` with `content: []RuntimeObject`, `named_content: std.StringHashMapUnmanaged(*Container)`, `name: ?[]const u8`, `flags: ContainerFlags` (packed struct with visits, turns, count_start_only bits). Arena-allocated; no individual frees.

Tests:
- Create Container with 3 content items; access by index
- Create Container with named sub-container; look up by name
- Flags: flags.visits == true when #f == 1
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Container with content array accessible by index
- [ ] #2 Named sub-containers looked up by name
- [ ] #3 ContainerFlags bits work correctly
<!-- AC:END -->
