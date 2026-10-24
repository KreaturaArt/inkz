# TASK-89: Tests: add direct coverage for player/flow.ink

- Status: Done
- Priority: low
- Labels: tests, coverage, fixtures, original
- Dependencies: —
- Created: 2026-04-08 · Updated: 2026-04-09

## Description

Add a direct unit test that exercises the original fixture `player/flow.ink`. This fixture is currently listed as unused in docs/Tests.md.

## Acceptance Criteria
- [x] Add a direct unit test that exercises the original fixture `player/flow.ink`.
- [x] Update coverage documentation so this fixture is no longer listed as unused.

## Final Summary

Added a compiler e2e test that compiles the original `player/flow.ink` fixture, checks that global tags are available, and verifies the prologue output reaches the first choice point. Updated docs/Tests.md to record the new direct coverage.
