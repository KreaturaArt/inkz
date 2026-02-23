---
id: TASK-7
title: ink.json loader
status: To Do
assignee: []
created_date: '2026-02-23 19:18'
labels:
  - layer-1
  - loader
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement `loadStory(allocator, json_text) !LoadedStory` in `src/runtime/json_loader.zig` using std.json. Parse inkVersion, root Container tree, listDefs. Map all JSON value types to RuntimeObject variants.

Tests:
- Load hello_world.ink.json: root has correct structure
- Load arithmetic.ink.json: ev/int/native_function objects parsed
- Load basic_tunnel.ink.json: named container "f" exists at root level
- Load list_basic_operations.ink.json: listDefs has "list" with 5 items
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 hello_world.ink.json loads with correct container structure
- [ ] #2 All JSON RuntimeObject types parsed correctly
- [ ] #3 Named containers parsed from object entries in arrays
- [ ] #4 listDefs parsed correctly
<!-- AC:END -->
