---
id: TASK-56
title: 'Tests: runtime/glue — remaining 3 fixtures'
status: Done
assignee: []
created_date: '2026-03-02 20:24'
updated_date: '2026-03-06 10:44'
labels:
  - tests
  - glue
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add story-level integration tests for three glue fixtures that currently have no test.

Fixtures to cover:
- `runtime/glue/implicit_inline_glue_b.ink.json`
- `runtime/glue/implicit_inline_glue_c.ink.json`
- `runtime/glue/left_right_glue_matching.ink.json`

Already covered: simple_glue, implicit_inline_glue.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 One test per fixture
- [ ] #2 Expected output asserted (glue should merge lines correctly)
- [ ] #3 All 3 tests pass with `zig build test`
<!-- AC:END -->
