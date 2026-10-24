# TASK-56: Tests: runtime/glue — remaining 3 fixtures

- Status: Done
- Priority: medium
- Labels: tests, glue
- Dependencies: —
- Created: 2026-03-02 · Updated: 2026-03-06

## Description

Add story-level integration tests for three glue fixtures that currently have no test.

Fixtures to cover:
- `runtime/glue/implicit_inline_glue_b.ink.json`
- `runtime/glue/implicit_inline_glue_c.ink.json`
- `runtime/glue/left_right_glue_matching.ink.json`

Already covered: simple_glue, implicit_inline_glue.

## Acceptance Criteria
- [ ] One test per fixture
- [ ] Expected output asserted (glue should merge lines correctly)
- [ ] All 3 tests pass with `zig build test`
