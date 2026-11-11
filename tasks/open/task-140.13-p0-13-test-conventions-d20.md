# TASK-140.13: P0.13 Test conventions (D20)

- Status: To Do
- Priority: high
- Labels: dod, tooling, testing
- Dependencies: TASK-140.2 (build steps), TASK-140.8 (lint)
- Parent: TASK-140
- Created: 2026-10-24 · Updated: 2026-11-11

## Description

Plan item P0.13 in `docs/DODMigrationPlan.md` §6 (Phase 0).

Add the `check() Fault` / `verify()` pattern to `src/core/` as the template, and a `zig build test-death` step that builds one child executable per death case and expects an abnormal exit.

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] A sample structure's corrupted state is detected through `check()`.
- [ ] A sample `test-death` case passes when the child panics and fails when it exits normally.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
