# TASK-9: CallStack

- Status: Done
- Priority: high
- Labels: layer-2, state
- Dependencies: —
- Created: 2026-02-23 · Updated: 2026-03-01

## Description

Implement CallStack, Thread, Element in src/runtime/callstack.zig. PushPopType enum. Element with push_pop_type, current_pointer, in_expression_evaluation, temporary_variables. Methods: currentElement, currentThread, push, pop, canPop.

## Acceptance Criteria
- [x] Initial callstack has 1 thread 1 element
- [x] Push/pop function frames work
- [x] canPop false at top level

## Implementation Notes

Implemented in src/runtime/callstack.zig. Element includes current_pointer: Pointer, in_expression_evaluation: bool, temporary_variables: VariablesState. Thread includes previous_pointer: Pointer for saving return address. Mismatched pop returns error.CallstackTypeMismatch. Verified by tests 19-22 (4 CallStack tests all pass).
