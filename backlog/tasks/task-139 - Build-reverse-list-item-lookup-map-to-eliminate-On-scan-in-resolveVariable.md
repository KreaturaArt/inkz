---
id: TASK-139
title: Build reverse list-item lookup map to eliminate O(n) scan in resolveVariable
status: Done
assignee: []
created_date: '2026-05-17 17:57'
updated_date: '2026-05-17 18:54'
labels:
  - runtime
  - performance
dependencies: []
references:
  - 'src/runtime/story.zig:2089-2105'
  - 'src/runtime/story.zig:initFromContainers'
  - 'src/runtime/story.zig:initFromJson'
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
## Context

`story.zig:resolveVariable()` (line ~2089) has a fallback that iterates all list definitions to find if `name` is a bare list item name (e.g. `red` → `Colour.red`). This runs a nested iterator on every undefined-variable lookup:

```zig
var def_it = self.list_defs.definitions.iterator();
while (def_it.next()) |def_entry| {
    const def = def_entry.value_ptr;
    if (def.items.get(name)) |val| { ... }  // second HashMap lookup
}
```

For a story with 5 list definitions each with 10 items, every "undefined variable" lookup does 5 HashMap iterations + up to 5 lookups. Happens during every expression that references a list item by bare name.

## Fix

At `Story.initFromJson` / `Story.initFromContainers`, build a flat reverse map:
```zig
list_item_lookup: std.StringHashMapUnmanaged(struct { origin: []const u8, value: i32 }) = .{}
```

Populated once:
```zig
var it = self.list_defs.definitions.iterator();
while (it.next()) |e| {
    var item_it = e.value_ptr.items.iterator();
    while (item_it.next()) |ie| {
        try self.list_item_lookup.put(arena, ie.key_ptr.*, .{
            .origin = e.key_ptr.*,
            .value = ie.value_ptr.*,
        });
    }
}
```

`resolveVariable` fallback becomes a single O(1) map lookup.

## Acceptance Criteria
<!-- AC:BEGIN -->
- All existing tests pass
- `resolveVariable` fallback is O(1) instead of O(n_defs)
<!-- SECTION:DESCRIPTION:END -->

- [x] #1 All tests pass
- [x] #2 resolveVariable list-item fallback uses a HashMap not an iterator loop
<!-- AC:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Added `ListItemEntry = struct { origin: []const u8, value: i32 }` and `list_item_lookup: StringHashMapUnmanaged(ListItemEntry)` to `Story`. Built once at init (both `initFromJson` and `initFromContainers`) via `buildListItemLookup()`, which iterates all list definitions and populates the reverse map (first-wins on name collision, matching prior iterator behavior). `resolveVariable` fallback now does a single `list_item_lookup.get(name)` call instead of iterating all list origins. All 549 tests pass.
<!-- SECTION:FINAL_SUMMARY:END -->
