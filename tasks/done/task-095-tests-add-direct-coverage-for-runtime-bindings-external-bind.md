# TASK-95: Tests: add direct coverage for runtime/bindings/external_binding.ink

- Status: Done
- Priority: low
- Labels: tests, coverage, fixtures, original
- Dependencies: —
- Created: 2026-04-08 · Updated: 2026-04-09

## Description

Add a direct unit test that exercises the original fixture `runtime/bindings/external_binding.ink`. This fixture is currently listed as unused in docs/Tests.md.

## Acceptance Criteria
- [x] Add a direct unit test that exercises the original fixture `runtime/bindings/external_binding.ink`.
- [x] Update coverage documentation so this fixture is no longer listed as unused.

## Final Summary

Added a compiler e2e test that compiles the original `runtime/bindings/external_binding.ink` fixture, binds the external functions, and verifies the compiler-path output. Updated docs/Tests.md to record the new direct coverage.
