# TASK-63: Tests: runtime/sequences — remaining 5 fixtures

- Status: Done
- Priority: medium
- Labels: tests, sequences
- Dependencies: —
- Created: 2026-03-02 · Updated: 2026-03-06

## Description

Add story-level integration tests for five sequence fixtures that currently have no test.

Fixtures to cover:
- `runtime/sequences/blanks_in_inline_sequences.ink.json`
- `runtime/sequences/empty_sequence_content.ink.json`
- `runtime/sequences/gather_read_count_with_initial_sequence.ink.json`
- `runtime/sequences/leading_newline_multiline_sequence.ink.json`
- `runtime/sequences/shuffle_stack_muddying.ink.json`  (random — assert structure not exact string)

Already covered: all_sequence_types.

## Acceptance Criteria
- [ ] One test per fixture
- [ ] Deterministic fixtures assert exact output; shuffle_stack_muddying asserts non-empty / structural correctness
- [ ] All 5 tests pass with `zig build test`
