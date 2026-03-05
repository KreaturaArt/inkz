---
id: TASK-68
title: 'Tests: runtime/weaves — all 6 fixtures'
status: To Do
assignee: []
created_date: '2026-03-02 20:24'
labels:
  - tests
  - weaves
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add story-level integration tests for all six weave fixtures (none currently covered).

Fixtures to cover:
- `runtime/weaves/conditional_choice_in_weave.ink.json`
- `runtime/weaves/conditional_choice_in_weave_2.ink.json`
- `runtime/weaves/unbalanced_weave_indentation.ink.json`
- `runtime/weaves/weave_gathers.ink.json`
- `runtime/weaves/weave_options.ink.json`
- `runtime/weaves/weave_within_sequence.ink.json`

For choice-driven weaves, drive a known path via `chooseChoiceIndex` and assert output.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 One test per fixture
- [ ] #2 Choice-driven weaves use chooseChoiceIndex with a known path
- [ ] #3 All 6 tests pass with `zig build test`
<!-- AC:END -->
