---
id: TASK-90
title: 'Tests: add direct coverage for player/functions.ink'
status: Done
assignee: []
created_date: '2026-04-08 13:52'
updated_date: '2026-04-09 16:24'
labels:
  - tests
  - coverage
  - fixtures
  - original
dependencies: []
priority: low
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add a direct unit test that exercises the original fixture `player/functions.ink`. This fixture is currently listed as unused in docs/Tests.md.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Add a direct unit test that exercises the original fixture `player/functions.ink`.
- [x] #2 Update coverage documentation so this fixture is no longer listed as unused.
<!-- AC:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Added a compiler e2e test that compiles the original `player/functions.ink` fixture, binds the external function, and verifies the returned output. Fixed compiler external-call serialization to emit `x()` with `exArgs`, matching the runtime loader. Updated docs/Tests.md to record the new direct coverage.
<!-- SECTION:FINAL_SUMMARY:END -->
