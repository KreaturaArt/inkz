# TASK-58: Tests: runtime/lists — remaining 4 fixtures

- Status: Done
- Priority: medium
- Labels: tests, lists
- Dependencies: —
- Created: 2026-03-02 · Updated: 2026-03-06

## Description

Add story-level integration tests for four list fixtures that currently have no test.

Fixtures to cover:
- `runtime/lists/contains_empty_list_always_false.ink.json`
- `runtime/lists/empty_list_origin_after_assignment.ink.json`
- `runtime/lists/empty_list_origin.ink.json`
- `runtime/lists/list_random.ink.json`  (note: random output — assert structure, not exact string)

Already covered: list_basic_operations, list_mixed_items, more_list_operations, list_range, list_save_load.

## Acceptance Criteria
- [ ] One test per fixture
- [ ] Deterministic fixtures assert exact output; list_random asserts non-empty output and valid list format
- [ ] All 4 tests pass with `zig build test`
