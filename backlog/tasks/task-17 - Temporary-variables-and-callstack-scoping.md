---
id: TASK-17
title: Temporary variables and callstack scoping
status: In Progress
assignee: []
created_date: '2026-02-23 19:18'
updated_date: '2026-03-01 17:31'
labels:
  - layer-4
  - variables
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement temporary variable scoping in `src/runtime/variables.zig` and `src/runtime/callstack.zig`.

- `.variable_assignment` with `is_global==false` (temp=): store in `currentElement().temporary_variables`
- VAR? resolution order: search `temporary_variables` on each callstack element top-to-bottom, then fall back to globals
- On `pop()` of a callstack element, its `temporary_variables` are deinit'd (discarded)

Tests:
- Unit: push function frame, assign temp `"t"=42`; lookup finds `.int(42)`
- Unit: pop the frame; lookup for `"t"` falls through to globals; returns `null` if not in globals
- Unit: temp in inner frame shadows global with same name; after pop, global value restored
- `callstack/callstack_evaluation.ink.json` → determine expected output by inspecting the `.ink` source before writing the test
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Temp var found in current callstack frame
- [ ] #2 After pop, temp var no longer visible
- [ ] #3 Temp shadows global of same name within frame
- [ ] #4 callstack_evaluation.ink.json produces correct output (verify expected string before implementing)
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implementation complete in src/runtime/story.zig and variables.zig. temp= stores in currentElement().temporary_variables; VAR? resolution order searches temp frames top-to-bottom before globals; popped frame's temps are deinit'd. Exercised implicitly by factorial_recursive test (uses temp vars for recursion). No explicit unit tests for temp var scoping or callstack_evaluation.ink.json fixture test written yet.
<!-- SECTION:NOTES:END -->
