---
id: TASK-54
title: 'Tests: runtime/evaluation — remaining 7 fixtures'
status: To Do
assignee: []
created_date: '2026-03-02 20:23'
labels:
  - tests
  - evaluation
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add story-level integration tests for seven evaluation fixtures that currently have no test.

Fixtures to cover:
- `runtime/evaluation/basic_string_literals.ink.json`
- `runtime/evaluation/evaluating_function_variable_state_bug.ink.json`
- `runtime/evaluation/evaluating_ink_functions_from_game.ink.json`  (note: `_2` is already covered)
- `runtime/evaluation/evaluation_stack_leaks.ink.json`
- `runtime/evaluation/factorial_by_reference.ink.json`
- `runtime/evaluation/increment.ink.json`
- `runtime/evaluation/literal_unary.ink.json`

Already covered: arithmetic, factorial_recursive, evaluating_ink_functions_from_game_2.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 One test per fixture
- [ ] #2 Expected output asserted
- [ ] #3 All 7 tests pass with `zig build test`
<!-- AC:END -->
