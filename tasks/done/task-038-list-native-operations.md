# TASK-38: List native operations

- Status: Done
- Priority: high
- Labels: layer-10, lists
- Dependencies: —
- Created: 2026-02-23 · Updated: 2026-03-02

## Description

Implement list operator overloads in `callNativeFunction` in `src/runtime/evaluation.zig` and `src/runtime/lists.zig`.

Detect list operands by checking for `.list` variant. Overloads:
- `add` (list + list): union — all items from both
- `subtract` (list - list): remove items in right from left
- `list_intersect` (`L^`): items present in both
- `list_has` (`?`): right-hand list/item is a subset of left; result `.int(1)` or `.int(0)`
- `list_hasnt` (`!?`): inverse of has
- `equal` (list == list): same set of items; result `.int(0)` or `.int(1)`
- `not_equal`: inverse
- List + int: add item at integer offset from the list's origin
- List comparison with int: compare max value of list to int

Tests:
- `lists/list_basic_operations.ink.json` → all 6 output lines correct
- `lists/list_mixed_items.ink.json` → multi-origin lists handled correctly

## Acceptance Criteria
- [x] list_basic_operations.ink.json produces all 6 correct lines
- [x] list_mixed_items.ink.json produces correct output
- [x] Union, subtract, intersect operations correct
- [x] has/hasnt return 0 or 1 correctly

## Final Summary

Implemented list native operations in evaluation.zig and story.zig:
- Added helper functions: createListUnion, createListDiff, createListIntersect, listContainsAll, listEquals
- Updated callNativeFunction: add (list union), subtract (list diff), list_intersect, list_has (?), list_hasnt (!?)
- Added list equality to valuesEqual
- Fixed dispatchObject: .list now pushes the actual InkList pointer onto eval stack (was pushing .void)
- Added .list case to appendObjectText: calls toDisplayString and appends to output
- Tests: list_basic_operations (6 lines: union, intersect, has, hasnt) and list_mixed_items (multi-origin union)
