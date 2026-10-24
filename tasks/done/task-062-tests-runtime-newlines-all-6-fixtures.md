# TASK-62: Tests: runtime/newlines — all 6 fixtures

- Status: Done
- Priority: medium
- Labels: tests, newlines
- Dependencies: —
- Created: 2026-03-02 · Updated: 2026-03-06

## Description

Add story-level integration tests for all six newline fixtures (none currently covered).

Fixtures to cover:
- `runtime/newlines/newline_at_start_of_multiline_conditional.ink.json`
- `runtime/newlines/newline_consistency_1.ink.json`
- `runtime/newlines/newline_consistency_2.ink.json`
- `runtime/newlines/newline_consistency_3.ink.json`
- `runtime/newlines/newlines_trimming_with_func_external_fallback.ink.json`
- `runtime/newlines/newlines_with_string_eval.ink.json`

Newline handling is subtle — assert exact output strings including `\n` placement.

## Acceptance Criteria
- [ ] One test per fixture
- [ ] Exact output string asserted including newline placement
- [ ] All 6 tests pass with `zig build test`
