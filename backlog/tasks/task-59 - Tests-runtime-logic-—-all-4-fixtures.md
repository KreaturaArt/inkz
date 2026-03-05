---
id: TASK-59
title: 'Tests: runtime/logic — all 4 fixtures'
status: To Do
assignee: []
created_date: '2026-03-02 20:24'
labels:
  - tests
  - logic
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add story-level integration tests for all four logic fixtures (none currently covered).

Fixtures to cover:
- `runtime/logic/logic_lines_with_newlines.ink.json`
- `runtime/logic/multiline_logic_with_glue.ink.json`
- `runtime/logic/nested_pass_by_reference.ink.json`
- `runtime/logic/print_num.ink.json`
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 One test per fixture
- [ ] #2 Each test asserts exact output string
- [ ] #3 All 4 tests pass with `zig build test`
<!-- AC:END -->
