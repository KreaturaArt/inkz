---
id: TASK-61
title: 'Tests: runtime/multiflow — 1 remaining fixture'
status: Done
assignee: []
created_date: '2026-03-02 20:24'
updated_date: '2026-03-06 13:58'
labels:
  - tests
  - multiflow
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add a story-level integration test for the one multiflow fixture that currently has no test.

Fixture to cover:
- `runtime/multiflow/multi_flow_save_load_threads.ink.json`

Already covered: multi_flow_basics.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Test covers save/load combined with multi-flow and threads
- [ ] #2 Expected output or state asserted
- [ ] #3 Test passes with `zig build test`
<!-- AC:END -->
