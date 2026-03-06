---
id: TASK-63
title: 'Tests: runtime/sequences — remaining 5 fixtures'
status: Done
assignee: []
created_date: '2026-03-02 20:24'
updated_date: '2026-03-06 10:44'
labels:
  - tests
  - sequences
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add story-level integration tests for five sequence fixtures that currently have no test.

Fixtures to cover:
- `runtime/sequences/blanks_in_inline_sequences.ink.json`
- `runtime/sequences/empty_sequence_content.ink.json`
- `runtime/sequences/gather_read_count_with_initial_sequence.ink.json`
- `runtime/sequences/leading_newline_multiline_sequence.ink.json`
- `runtime/sequences/shuffle_stack_muddying.ink.json`  (random — assert structure not exact string)

Already covered: all_sequence_types.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 One test per fixture
- [ ] #2 Deterministic fixtures assert exact output; shuffle_stack_muddying asserts non-empty / structural correctness
- [ ] #3 All 5 tests pass with `zig build test`
<!-- AC:END -->
