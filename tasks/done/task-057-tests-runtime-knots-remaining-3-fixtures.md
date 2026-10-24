# TASK-57: Tests: runtime/knots — remaining 3 fixtures

- Status: Done
- Priority: medium
- Labels: tests, knots
- Dependencies: —
- Created: 2026-03-02 · Updated: 2026-03-06

## Description

Add story-level integration tests for three knot fixtures that currently have no test.

Fixtures to cover:
- `runtime/knots/knot_do_not_gather.ink.json`
- `runtime/knots/knot_thread_interaction.ink.json`
- `runtime/knots/knot_thread_interaction_2.ink.json`

Already covered: knot_stitch_gather_counts.

## Acceptance Criteria
- [ ] One test per fixture
- [ ] Expected output asserted
- [ ] All 3 tests pass with `zig build test`
