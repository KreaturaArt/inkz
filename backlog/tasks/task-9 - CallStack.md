---
id: TASK-9
title: CallStack
status: To Do
assignee: []
created_date: '2026-02-23 19:18'
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
- [ ] #1 Initial callstack has 1 thread 1 element
- [ ] #2 Push/pop function frames work
- [ ] #3 canPop false at top level
<!-- AC:END -->
