---
id: TASK-37
title: InkList type and JSON value parsing
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
Implement the `InkList` runtime type in `src/runtime/lists.zig` and wire it into the JSON loader.

- `InkListItem = struct{ origin_name: []const u8, item_name: []const u8 }`
- `InkList = struct{ items: std.AutoHashMap(InkListItem, i32), origins: [][]const u8 }` — maps each item to its integer value; `origins` tracks which ListDefinitions this list draws from
- `InkList.format(writer)`: output comma-separated item names sorted by integer value (e.g. `"a, c"`)
- Replace the `.list(anyopaque)` stub in `RuntimeObject` (from TASK-4) with `.list(InkList)`
- Update `json_loader.zig` to parse `{"list": {"origin.item": value, ...}}` objects into `.list(InkList)` instead of `.void`

Tests:
- Create `InkList` with items `a=1` and `c=3` from origin `"list"`; `format()` → `"a, c"`
- Load `lists/list_basic_operations.ink.json`: the global variable `"list"` in `"global decl"` is now `.list(...)` not `.void`
- Empty InkList formats as `""` (empty string)
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 InkList format() produces comma-separated sorted item names
- [ ] #2 list_basic_operations.ink.json: global list variable is .list not .void
- [ ] #3 Empty InkList formats as empty string
- [ ] #4 JSON loader correctly parses {"list": {...}} objects
<!-- AC:END -->
