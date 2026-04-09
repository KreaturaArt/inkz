---
id: TASK-97
title: 'Tests: add direct coverage for runtime/bindings/lookup_safe_or_not.ink'
status: Done
assignee: []
created_date: '2026-04-08 13:53'
updated_date: '2026-04-09 16:38'
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
Add a direct unit test that exercises the original fixture `runtime/bindings/lookup_safe_or_not.ink`. This fixture is currently listed as unused in docs/Tests.md.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Add a direct unit test that exercises the original fixture `runtime/bindings/lookup_safe_or_not.ink`.
- [x] #2 Update coverage documentation so this fixture is no longer listed as unused.
<!-- AC:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Added a compiler e2e test that compiles the original `runtime/bindings/lookup_safe_or_not.ink` fixture, binds `myAction`, and verifies the expected text output. Updated docs/Tests.md to record the new direct coverage.
<!-- SECTION:FINAL_SUMMARY:END -->
