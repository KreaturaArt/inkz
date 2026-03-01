---
id: TASK-9
title: CallStack
status: Done
assignee: []
created_date: '2026-02-23 19:18'
updated_date: '2026-03-01 17:31'
labels:
  - layer-2
  - state
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement CallStack, Thread, Element in src/runtime/callstack.zig. PushPopType enum. Element with push_pop_type, current_pointer, in_expression_evaluation, temporary_variables. Methods: currentElement, currentThread, push, pop, canPop.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Initial callstack has 1 thread 1 element
- [x] #2 Push/pop function frames work
- [x] #3 canPop false at top level
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented in src/runtime/callstack.zig. Element includes current_pointer: Pointer, in_expression_evaluation: bool, temporary_variables: VariablesState. Thread includes previous_pointer: Pointer for saving return address. Mismatched pop returns error.CallstackTypeMismatch. Verified by tests 19-22 (4 CallStack tests all pass).
<!-- SECTION:NOTES:END -->
