---
id: TASK-70
title: 'Tests: player/ — all 7 integration fixtures'
status: To Do
assignee: []
created_date: '2026-03-02 20:24'
labels:
  - tests
  - player
  - integration
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add story-level integration tests for all seven player fixtures (none currently covered). These are higher-level scenarios exercising the public API.

Fixtures to cover:
- `player/error_and_exceptions.ink.json`
- `player/flow.ink.json`
- `player/functions.ink.json`
- `player/ink_error.ink.json`
- `player/ink_list_roundtrip.ink.json`
- `player/variable_observation.ink.json`
- `player/variables.ink.json`

Notes:
- `error_and_exceptions` and `ink_error` should assert that the runtime surfaces the appropriate error.
- `functions` exercises `evaluateFunction` — bind appropriate external functions if needed.
- `variable_observation` exercises `observeVariable`.
- `ink_list_roundtrip` exercises save/load with list variables.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 One test per fixture
- [ ] #2 Error fixtures assert expected error type
- [ ] #3 Observer fixture registers and verifies callback fires
- [ ] #4 Save/load fixture asserts round-trip fidelity
- [ ] #5 All 7 tests pass with `zig build test`
<!-- AC:END -->
