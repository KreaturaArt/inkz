# TASK-68: Tests: runtime/weaves — all 6 fixtures

- Status: Done
- Priority: medium
- Labels: tests, weaves
- Dependencies: —
- Created: 2026-03-02 · Updated: 2026-03-06

## Description

Add story-level integration tests for all six weave fixtures (none currently covered).

Fixtures to cover:
- `runtime/weaves/conditional_choice_in_weave.ink.json`
- `runtime/weaves/conditional_choice_in_weave_2.ink.json`
- `runtime/weaves/unbalanced_weave_indentation.ink.json`
- `runtime/weaves/weave_gathers.ink.json`
- `runtime/weaves/weave_options.ink.json`
- `runtime/weaves/weave_within_sequence.ink.json`

For choice-driven weaves, drive a known path via `chooseChoiceIndex` and assert output.

## Acceptance Criteria
- [ ] One test per fixture
- [ ] Choice-driven weaves use chooseChoiceIndex with a known path
- [ ] All 6 tests pass with `zig build test`
