---
id: TASK-36
title: ListDefinition and listDefs parsing
status: To Do
assignee: []
created_date: '2026-02-23 19:45'
labels:
  - layer-10
  - lists
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement list type definitions in `src/runtime/lists.zig` and extend the JSON loader.

- `ListDefinition = struct{ name: []const u8, items: std.StringHashMap(i32) }` — maps item name to integer value
- `ListDefinitionsOrigin = struct{ definitions: std.StringHashMap(ListDefinition) }`
- Helper methods: `valueForItem(name) ?i32`, `itemForValue(value) ?[]const u8`
- Extend `LoadedStory` in `json_loader.zig` to include `list_definitions: ListDefinitionsOrigin`
- Parse the `listDefs` JSON object: `{ "origin_name": { "item_name": value, ... }, ... }`

Tests:
- Load `lists/list_basic_operations.ink.json`: `list_definitions.definitions.get("list")` has 5 items (`a=1, b=2, c=3, d=4, e=5`)
- `valueForItem("c")` returns `3`
- `itemForValue(3)` returns `"c"`
- Load a fixture with no `listDefs`: `list_definitions.definitions.count() == 0`
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 listDefs parsed into ListDefinitionsOrigin correctly
- [ ] #2 valueForItem returns correct value
- [ ] #3 itemForValue returns correct name
- [ ] #4 Empty listDefs handled without error
<!-- AC:END -->
