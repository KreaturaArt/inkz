---
id: TASK-64
title: 'Tests: runtime/strings — remaining 2 fixtures'
status: Done
assignee: []
created_date: '2026-03-02 20:24'
updated_date: '2026-03-06 10:44'
labels:
  - tests
  - strings
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add story-level integration tests for two string fixtures that currently have no test.

Fixtures to cover:
- `runtime/strings/string_contains.ink.json`
- `runtime/strings/strings_in_choices.ink.json`

Already covered: string_constants, string_type_coercion.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 One test per fixture
- [ ] #2 Expected output or choice text asserted
- [ ] #3 Both tests pass with `zig build test`
<!-- AC:END -->
