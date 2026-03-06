---
id: TASK-65
title: 'Tests: runtime/tags — remaining 4 fixtures'
status: Done
assignee: []
created_date: '2026-03-02 20:24'
updated_date: '2026-03-06 13:58'
labels:
  - tests
  - tags
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add story-level integration tests for four tag fixtures that currently have no test.

Fixtures to cover:
- `runtime/tags/tags_dynamic_content.ink.json`
- `runtime/tags/tags_in_choice.ink.json`
- `runtime/tags/tags_in_seq.ink.json`
- `runtime/tags/tags_on_choice.ink.json`

Already covered: tags (via tags.ink.json).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 One test per fixture
- [ ] #2 Tag content and output text both asserted
- [ ] #3 All 4 tests pass with `zig build test`
<!-- AC:END -->
