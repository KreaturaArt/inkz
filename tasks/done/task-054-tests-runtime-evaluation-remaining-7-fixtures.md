# TASK-54: Tests: runtime/evaluation — remaining 7 fixtures

- Status: Done
- Priority: medium
- Labels: tests, evaluation
- Dependencies: —
- Created: 2026-03-02 · Updated: 2026-03-06

## Description

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

## Acceptance Criteria
- [ ] One test per fixture
- [ ] Expected output asserted
- [ ] All 7 tests pass with `zig build test`
