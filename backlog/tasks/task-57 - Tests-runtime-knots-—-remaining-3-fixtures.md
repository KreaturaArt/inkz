---
id: TASK-57
title: 'Tests: runtime/knots — remaining 3 fixtures'
status: Done
assignee: []
created_date: '2026-03-02 20:24'
updated_date: '2026-03-06 10:44'
labels:
  - tests
  - knots
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add story-level integration tests for three knot fixtures that currently have no test.

Fixtures to cover:
- `runtime/knots/knot_do_not_gather.ink.json`
- `runtime/knots/knot_thread_interaction.ink.json`
- `runtime/knots/knot_thread_interaction_2.ink.json`

Already covered: knot_stitch_gather_counts.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 One test per fixture
- [ ] #2 Expected output asserted
- [ ] #3 All 3 tests pass with `zig build test`
<!-- AC:END -->
