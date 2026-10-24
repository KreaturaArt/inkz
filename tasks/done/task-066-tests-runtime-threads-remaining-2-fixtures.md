# TASK-66: Tests: runtime/threads — remaining 2 fixtures

- Status: Done
- Priority: medium
- Labels: tests, threads
- Dependencies: —
- Created: 2026-03-02 · Updated: 2026-03-06

## Description

Add story-level integration tests for two thread fixtures that currently have no test.

Fixtures to cover:
- `runtime/threads/thread_in_logic.ink.json`
- `runtime/threads/top_flow_terminator_should_not_kill_thread_choices.ink.json`

Already covered: thread_done, multi_thread.

## Acceptance Criteria
- [ ] One test per fixture
- [ ] Expected output or choice assertions
- [ ] Both tests pass with `zig build test`
