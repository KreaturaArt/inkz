# TASK-143.3: P3.3 Structural parity with the old `Story.containers`

- Status: To Do
- Priority: high
- Labels: dod, loader
- Dependencies: TASK-142 (Program and builder)
- Parent: TASK-143
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P3.3 in `docs/DODMigrationPlan.md` §6 (Phase 3).

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] Parity on every fixture.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
