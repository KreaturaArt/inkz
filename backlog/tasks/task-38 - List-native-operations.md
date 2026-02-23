---
id: TASK-38
title: List native operations
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
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 list_basic_operations.ink.json produces all 6 correct lines
- [ ] #2 list_mixed_items.ink.json produces correct output
- [ ] #3 Union, subtract, intersect operations correct
- [ ] #4 has/hasnt return 0 or 1 correctly
<!-- AC:END -->
