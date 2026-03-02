---
id: TASK-39
title: >-
  List builtins (LIST_MIN, LIST_MAX, LIST_ALL, LIST_INVERT, LIST_RANGE,
  LIST_COUNT, LIST_VALUE)
status: Done
assignee: []
created_date: '2026-02-23 19:45'
updated_date: '2026-03-02 05:05'
labels:
  - layer-10
  - lists
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement list builtin functions dispatched via `ControlCommand` in `src/runtime/evaluation.zig`.

- `.list_from_int` (`listInt`): pop int + origin-name string; push single-item InkList for that value
- `.list_range` (`range`): pop max-int, min-int, list; push sub-range InkList (items with values in [min, max])
- `.list_random` (`lrnd`): pop list; push random single-item InkList (use `story_seed`)
- Via `NativeFunction` dispatch (these appear as native function calls):
  - `LIST_MIN`: pop list; push single-item list of min-value item
  - `LIST_MAX`: pop list; push single-item list of max-value item
  - `LIST_ALL`: pop list; push all defined items in the list's origin(s)
  - `LIST_INVERT`: pop list; push complement within origin(s)
  - `LIST_COUNT`: pop list; push `.int` of item count
  - `LIST_VALUE`: pop list; push `.int` of max item value (or 0 if empty)

Tests:
- `lists/more_list_operations.ink.json` → correct outputs for LIST_MIN, LIST_MAX, LIST_ALL, LIST_INVERT, LIST_COUNT, LIST_VALUE
- `lists/list_range.ink.json` → range sub-list is correct
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 more_list_operations.ink.json produces correct output
- [x] #2 list_range.ink.json produces correct output
- [x] #3 LIST_ALL returns all items in origin
- [x] #4 LIST_INVERT returns complement
- [x] #5 LIST_COUNT and LIST_VALUE correct
<!-- AC:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Implemented list builtins across multiple files:
- value.zig: Added LIST_VALUE, LIST_ALL, LIST_INVERT, LIST_COUNT, LIST_MIN, LIST_MAX to NativeFunction enum and fromString
- lists.zig: Added `origins: []const []const u8` field to InkList for LIST_ALL/LIST_INVERT
- json_loader.zig: Parse "origins" JSON array when creating InkList values
- story.zig: 
  - Added list_defs: ListDefinitionsOrigin field and parsing in initFromJson
  - resolveVariable fallback: when var not found, check listDef item names, return single-item InkList
  - handleNativeFunction: handles list_value, list_count, list_min, list_max, list_all, list_invert
  - expandListToAll helper: infers origins from item keys AND origins field, retrieves all items from list_defs
  - listInt control command: pop int+origin string, look up item by value in listDefs, push InkList
  - list_range control command: pop max, min, list; return items with values in [min,max]
  - list_random control command: pop list, pick random item based on story_seed
  - Fixed variable_assignment re-assignments (is_new_decl=false): search temps first, then globals
- evaluation.zig: Added unreachable stub for new functions (handled by story before reaching eval)
- Tests: more_list_operations (LIST_VALUE, listInt, LIST_ALL, LIST_INVERT) and list_range pass
<!-- SECTION:FINAL_SUMMARY:END -->
