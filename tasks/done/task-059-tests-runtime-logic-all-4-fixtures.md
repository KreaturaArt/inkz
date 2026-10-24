# TASK-59: Tests: runtime/logic — all 4 fixtures

- Status: Done
- Priority: medium
- Labels: tests, logic
- Dependencies: —
- Created: 2026-03-02 · Updated: 2026-03-06

## Description

Add story-level integration tests for all four logic fixtures (none currently covered).

Fixtures to cover:
- `runtime/logic/logic_lines_with_newlines.ink.json`
- `runtime/logic/multiline_logic_with_glue.ink.json`
- `runtime/logic/nested_pass_by_reference.ink.json`
- `runtime/logic/print_num.ink.json`

## Acceptance Criteria
- [ ] One test per fixture
- [ ] Each test asserts exact output string
- [ ] All 4 tests pass with `zig build test`
