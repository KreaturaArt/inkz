---
id: TASK-88
title: 'Tests: add direct coverage for player/error_and_exceptions.ink'
status: Done
assignee: []
created_date: '2026-04-08 13:52'
updated_date: '2026-04-09 14:37'
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
Add a direct unit test that exercises the original fixture `player/error_and_exceptions.ink`. This fixture is currently listed as unused in docs/Tests.md.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Add a direct unit test that exercises the original fixture `player/error_and_exceptions.ink`.
- [x] #2 Update coverage documentation so this fixture is no longer listed as unused.
<!-- AC:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Added a compiler e2e test that compiles the original `player/error_and_exceptions.ink` fixture, loads it in the runtime, navigates to `knot`, and verifies the emitted text. Updated docs/Tests.md to record the new direct coverage.
<!-- SECTION:FINAL_SUMMARY:END -->
