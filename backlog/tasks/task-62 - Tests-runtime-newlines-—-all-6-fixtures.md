---
id: TASK-62
title: 'Tests: runtime/newlines — all 6 fixtures'
status: To Do
assignee: []
created_date: '2026-03-02 20:24'
labels:
  - tests
  - newlines
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add story-level integration tests for all six newline fixtures (none currently covered).

Fixtures to cover:
- `runtime/newlines/newline_at_start_of_multiline_conditional.ink.json`
- `runtime/newlines/newline_consistency_1.ink.json`
- `runtime/newlines/newline_consistency_2.ink.json`
- `runtime/newlines/newline_consistency_3.ink.json`
- `runtime/newlines/newlines_trimming_with_func_external_fallback.ink.json`
- `runtime/newlines/newlines_with_string_eval.ink.json`

Newline handling is subtle — assert exact output strings including `\n` placement.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 One test per fixture
- [ ] #2 Exact output string asserted including newline placement
- [ ] #3 All 6 tests pass with `zig build test`
<!-- AC:END -->
