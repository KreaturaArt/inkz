# TASK-93: Tests: add direct coverage for player/variable_observation.ink

- Status: Done
- Priority: low
- Labels: tests, coverage, fixtures, original
- Dependencies: —
- Created: 2026-04-08 · Updated: 2026-04-09

## Description

Add a direct unit test that exercises the original fixture `player/variable_observation.ink`. This fixture is currently listed as unused in docs/Tests.md.

## Acceptance Criteria
- [x] Add a direct unit test that exercises the original fixture `player/variable_observation.ink`.
- [x] Update coverage documentation so this fixture is no longer listed as unused.

## Final Summary

Added a compiler e2e test that compiles the original `player/variable_observation.ink` fixture and verifies the initial global variable values. Updated docs/Tests.md to record the new direct coverage.
