---
id: TASK-39
title: >-
  List builtins (LIST_MIN, LIST_MAX, LIST_ALL, LIST_INVERT, LIST_RANGE,
  LIST_COUNT, LIST_VALUE)
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
- [ ] #1 more_list_operations.ink.json produces correct output
- [ ] #2 list_range.ink.json produces correct output
- [ ] #3 LIST_ALL returns all items in origin
- [ ] #4 LIST_INVERT returns complement
- [ ] #5 LIST_COUNT and LIST_VALUE correct
<!-- AC:END -->
