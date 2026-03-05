---
id: TASK-48
title: 'Tests: runtime/booleans — remaining 6 fixtures'
status: Done
assignee: []
created_date: '2026-03-02 20:23'
updated_date: '2026-03-02 20:37'
labels:
  - tests
  - booleans
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add story-level integration tests for the six boolean fixtures that currently have no test.

Each test should load the fixture, run `story.cont()`, and assert the expected output string.

Fixtures to cover:
- `runtime/booleans/false_plus_false.ink.json`
- `runtime/booleans/list_hasnt.ink.json`
- `runtime/booleans/not_one.ink.json`
- `runtime/booleans/true_equals_one.ink.json`
- `runtime/booleans/true_plus_one.ink.json`
- `runtime/booleans/two_plus_true.ink.json`

Reference existing tests in `src/runtime/story.zig` (e.g. "Story not_true", "Story true_plus_true") for the test pattern.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 One test per fixture listed above
- [x] #2 Each test asserts exact expected output
- [x] #3 All 6 tests pass with `zig build test`
<!-- AC:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Added 6 tests in `src/runtime/story.zig` adjacent to the existing boolean tests:
- `Story false_plus_false` → `"0\n"`
- `Story not_one` → `"0\n"`
- `Story true_equals_one` → `"1\n"`
- `Story true_plus_one` → `"2\n"`
- `Story two_plus_true` → `"3\n"`
- `Story list_hasnt` → `"1\n"` (c not in {b,d})
<!-- SECTION:FINAL_SUMMARY:END -->
