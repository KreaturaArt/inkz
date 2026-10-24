# TASK-70: Tests: player/ — all 7 integration fixtures

- Status: Done
- Priority: medium
- Labels: tests, player, integration
- Dependencies: —
- Created: 2026-03-02 · Updated: 2026-03-06

## Description

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

## Acceptance Criteria
- [ ] One test per fixture
- [ ] Error fixtures assert expected error type
- [ ] Observer fixture registers and verifies callback fires
- [ ] Save/load fixture asserts round-trip fidelity
- [ ] All 7 tests pass with `zig build test`
