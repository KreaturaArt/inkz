---
id: TASK-66
title: 'Tests: runtime/threads — remaining 2 fixtures'
status: Done
assignee: []
created_date: '2026-03-02 20:24'
updated_date: '2026-03-06 13:58'
labels:
  - tests
  - threads
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add story-level integration tests for two thread fixtures that currently have no test.

Fixtures to cover:
- `runtime/threads/thread_in_logic.ink.json`
- `runtime/threads/top_flow_terminator_should_not_kill_thread_choices.ink.json`

Already covered: thread_done, multi_thread.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 One test per fixture
- [ ] #2 Expected output or choice assertions
- [ ] #3 Both tests pass with `zig build test`
<!-- AC:END -->
