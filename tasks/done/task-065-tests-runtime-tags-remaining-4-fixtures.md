# TASK-65: Tests: runtime/tags — remaining 4 fixtures

- Status: Done
- Priority: medium
- Labels: tests, tags
- Dependencies: —
- Created: 2026-03-02 · Updated: 2026-03-06

## Description

Add story-level integration tests for four tag fixtures that currently have no test.

Fixtures to cover:
- `runtime/tags/tags_dynamic_content.ink.json`
- `runtime/tags/tags_in_choice.ink.json`
- `runtime/tags/tags_in_seq.ink.json`
- `runtime/tags/tags_on_choice.ink.json`

Already covered: tags (via tags.ink.json).

## Acceptance Criteria
- [ ] One test per fixture
- [ ] Tag content and output text both asserted
- [ ] All 4 tests pass with `zig build test`
