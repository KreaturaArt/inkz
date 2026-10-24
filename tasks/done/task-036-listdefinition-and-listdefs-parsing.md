# TASK-36: ListDefinition and listDefs parsing

- Status: Done
- Priority: high
- Labels: layer-10, lists
- Dependencies: —
- Created: 2026-02-23 · Updated: 2026-03-02

## Description

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

## Acceptance Criteria
- [x] listDefs parsed into ListDefinitionsOrigin correctly
- [x] valueForItem returns correct value
- [x] itemForValue returns correct name
- [x] Empty listDefs handled without error

## Final Summary

Created src/runtime/lists.zig with ListDefinition (name, items: StringHashMapUnmanaged(i32), valueForItem, itemForValue) and ListDefinitionsOrigin (definitions map, parse() from std.json.Value, get() accessor). Tests: valueForItem/itemForValue unit test; parse from list_basic_operations.ink.json → "list" has 5 items (a=1..e=5), c=3, itemForValue(3)="c"; empty listDefs → count=0.
