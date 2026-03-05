---
id: TASK-52
title: 'Tests: runtime/conditions — all 5 fixtures'
status: Done
assignee: []
created_date: '2026-03-02 20:23'
updated_date: '2026-03-05 19:52'
labels:
  - tests
  - conditions
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add story-level integration tests for all five condition fixtures (none currently covered).

Fixtures to cover:
- `runtime/conditions/all_switch_branches_fail_is_clean.ink.json`
- `runtime/conditions/conditionals.ink.json`
- `runtime/conditions/else_branches.ink.json`
- `runtime/conditions/empty_multiline_conditional_branch.ink.json`
- `runtime/conditions/trivial_condition.ink.json`

These are all choice-free stories that should produce deterministic output from a single `cont()` call.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 One test per fixture
- [ ] #2 Each test asserts exact output string
- [ ] #3 All 5 tests pass with `zig build test`
<!-- AC:END -->
