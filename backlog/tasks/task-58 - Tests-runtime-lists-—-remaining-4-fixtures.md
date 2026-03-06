---
id: TASK-58
title: 'Tests: runtime/lists — remaining 4 fixtures'
status: Done
assignee: []
created_date: '2026-03-02 20:24'
updated_date: '2026-03-06 10:44'
labels:
  - tests
  - lists
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add story-level integration tests for four list fixtures that currently have no test.

Fixtures to cover:
- `runtime/lists/contains_empty_list_always_false.ink.json`
- `runtime/lists/empty_list_origin_after_assignment.ink.json`
- `runtime/lists/empty_list_origin.ink.json`
- `runtime/lists/list_random.ink.json`  (note: random output — assert structure, not exact string)

Already covered: list_basic_operations, list_mixed_items, more_list_operations, list_range, list_save_load.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 One test per fixture
- [ ] #2 Deterministic fixtures assert exact output; list_random asserts non-empty output and valid list format
- [ ] #3 All 4 tests pass with `zig build test`
<!-- AC:END -->
