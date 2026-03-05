---
id: TASK-50
title: 'Tests: runtime/callstack — 2 remaining fixtures'
status: Done
assignee: []
created_date: '2026-03-02 20:23'
updated_date: '2026-03-04 16:38'
labels:
  - tests
  - callstack
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add story-level integration tests for the two callstack fixtures that currently have no test.

Fixtures to cover:
- `runtime/callstack/call_stack_evaluation.ink.json`
- `runtime/callstack/clean_callstack_reset_on_path_choice.ink.json`

Already covered: `callstack_evaluation`.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 One test per fixture
- [ ] #2 Expected output asserted
- [ ] #3 Tests pass with `zig build test`
<!-- AC:END -->
