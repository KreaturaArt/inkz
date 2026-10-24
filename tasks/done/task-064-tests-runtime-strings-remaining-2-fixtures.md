# TASK-64: Tests: runtime/strings — remaining 2 fixtures

- Status: Done
- Priority: medium
- Labels: tests, strings
- Dependencies: —
- Created: 2026-03-02 · Updated: 2026-03-06

## Description

Add story-level integration tests for two string fixtures that currently have no test.

Fixtures to cover:
- `runtime/strings/string_contains.ink.json`
- `runtime/strings/strings_in_choices.ink.json`

Already covered: string_constants, string_type_coercion.

## Acceptance Criteria
- [ ] One test per fixture
- [ ] Expected output or choice text asserted
- [ ] Both tests pass with `zig build test`
