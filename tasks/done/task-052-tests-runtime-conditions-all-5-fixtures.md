# TASK-52: Tests: runtime/conditions — all 5 fixtures

- Status: Done
- Priority: medium
- Labels: tests, conditions
- Dependencies: —
- Created: 2026-03-02 · Updated: 2026-03-05

## Description

Add story-level integration tests for all five condition fixtures (none currently covered).

Fixtures to cover:
- `runtime/conditions/all_switch_branches_fail_is_clean.ink.json`
- `runtime/conditions/conditionals.ink.json`
- `runtime/conditions/else_branches.ink.json`
- `runtime/conditions/empty_multiline_conditional_branch.ink.json`
- `runtime/conditions/trivial_condition.ink.json`

These are all choice-free stories that should produce deterministic output from a single `cont()` call.

## Acceptance Criteria
- [ ] One test per fixture
- [ ] Each test asserts exact output string
- [ ] All 5 tests pass with `zig build test`
