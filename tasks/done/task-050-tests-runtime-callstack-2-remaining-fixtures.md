# TASK-50: Tests: runtime/callstack — 2 remaining fixtures

- Status: Done
- Priority: medium
- Labels: tests, callstack
- Dependencies: —
- Created: 2026-03-02 · Updated: 2026-03-04

## Description

Add story-level integration tests for the two callstack fixtures that currently have no test.

Fixtures to cover:
- `runtime/callstack/call_stack_evaluation.ink.json`
- `runtime/callstack/clean_callstack_reset_on_path_choice.ink.json`

Already covered: `callstack_evaluation`.

## Acceptance Criteria
- [ ] One test per fixture
- [ ] Expected output asserted
- [ ] Tests pass with `zig build test`
