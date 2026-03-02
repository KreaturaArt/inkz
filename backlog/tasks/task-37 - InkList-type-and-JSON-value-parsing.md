---
id: TASK-37
title: InkList type and JSON value parsing
status: Done
assignee: []
created_date: '2026-02-23 19:45'
updated_date: '2026-03-02 04:43'
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
- [x] #1 InkList format() produces comma-separated sorted item names
- [x] #2 list_basic_operations.ink.json: global list variable is .list not .void
- [x] #3 Empty InkList formats as empty string
- [x] #4 JSON loader correctly parses {"list": {...}} objects
<!-- AC:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Added InkList to lists.zig with items: StringHashMapUnmanaged(i32) keyed by "origin.item" strings, toDisplayString(alloc) for sorted comma-separated output, and maxValue() helper. Updated RuntimeObject.list from *anyopaque to *InkList. Updated json_loader to parse {"list": {...}} objects into .list(InkList) (arena-allocated). Note: Zig 0.16 requires "{f}" format specifier to call custom format methods; used toDisplayString instead. Tests: toDisplayString "a, c", empty "", JSON loader parses list_basic_operations correctly.
<!-- SECTION:FINAL_SUMMARY:END -->
