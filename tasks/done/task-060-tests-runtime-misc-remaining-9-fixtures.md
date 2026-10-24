# TASK-60: Tests: runtime/misc — remaining 9 fixtures

- Status: Done
- Priority: medium
- Labels: tests, misc
- Dependencies: —
- Created: 2026-03-02 · Updated: 2026-03-06

## Description

Add story-level integration tests for nine misc fixtures that currently have no test.

Fixtures to cover:
- `runtime/misc/end_of_content.ink.json`
- `runtime/misc/end.ink.json`
- `runtime/misc/end2.ink.json`
- `runtime/misc/escape_character.ink.json`
- `runtime/misc/identifiers_can_start_with_number.ink.json`
- `runtime/misc/include.ink.json`
- `runtime/misc/nested_include.ink.json`
- `runtime/misc/quote_character_significance.ink.json`
- `runtime/misc/whitespace.ink.json`

Already covered: hello_world, empty.

## Acceptance Criteria
- [ ] One test per fixture
- [ ] Expected output asserted
- [ ] All 9 tests pass with `zig build test`
