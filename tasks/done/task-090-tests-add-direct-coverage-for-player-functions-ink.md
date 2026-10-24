# TASK-90: Tests: add direct coverage for player/functions.ink

- Status: Done
- Priority: low
- Labels: tests, coverage, fixtures, original
- Dependencies: —
- Created: 2026-04-08 · Updated: 2026-04-09

## Description

Add a direct unit test that exercises the original fixture `player/functions.ink`. This fixture is currently listed as unused in docs/Tests.md.

## Acceptance Criteria
- [x] Add a direct unit test that exercises the original fixture `player/functions.ink`.
- [x] Update coverage documentation so this fixture is no longer listed as unused.

## Final Summary

Added a compiler e2e test that compiles the original `player/functions.ink` fixture, binds the external function, and verifies the returned output. Fixed compiler external-call serialization to emit `x()` with `exArgs`, matching the runtime loader. Updated docs/Tests.md to record the new direct coverage.
