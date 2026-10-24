# TASK-69: Tests: runtime/bindings — remaining 3 fixtures

- Status: Done
- Priority: medium
- Labels: tests, bindings
- Dependencies: —
- Created: 2026-03-02 · Updated: 2026-03-06

## Description

Add story-level integration tests for three binding fixtures that currently have no test.

Fixtures to cover:
- `runtime/bindings/game_ink_back_and_forth.ink.json`
- `runtime/bindings/lookup_safe_or_not.ink.json`
- `runtime/bindings/lookup_safe_or_not_with_post_glue.ink.json`

Already covered: external_binding, variable_observer.

These may require registering external functions before running — check the fixture's `.ink.json.import` sidecar to identify required externals.

## Acceptance Criteria
- [ ] One test per fixture
- [ ] Required external functions registered before cont()
- [ ] Expected output asserted
- [ ] All 3 tests pass with `zig build test`
