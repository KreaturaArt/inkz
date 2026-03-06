---
id: TASK-69
title: 'Tests: runtime/bindings — remaining 3 fixtures'
status: Done
assignee: []
created_date: '2026-03-02 20:24'
updated_date: '2026-03-06 13:59'
labels:
  - tests
  - bindings
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add story-level integration tests for three binding fixtures that currently have no test.

Fixtures to cover:
- `runtime/bindings/game_ink_back_and_forth.ink.json`
- `runtime/bindings/lookup_safe_or_not.ink.json`
- `runtime/bindings/lookup_safe_or_not_with_post_glue.ink.json`

Already covered: external_binding, variable_observer.

These may require registering external functions before running — check the fixture's `.ink.json.import` sidecar to identify required externals.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 One test per fixture
- [ ] #2 Required external functions registered before cont()
- [ ] #3 Expected output asserted
- [ ] #4 All 3 tests pass with `zig build test`
<!-- AC:END -->
