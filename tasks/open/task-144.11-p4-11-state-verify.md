# TASK-144.11: P4.11 `State.verify()`

- Status: To Do
- Priority: high
- Labels: dod, runtime, state
- Dependencies: TASK-143 (loader), TASK-140.10 (ground truth), TASK-140.11 (neutral test layer)
- Parent: TASK-144
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P4.11 in `docs/DODMigrationPlan.md` §6 (Phase 4).

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] It catches each seeded corruption: a frame range out of bounds, a dangling `StringReference`, temps outside their frame, a snapshot range out of bounds, and a corrupt parking directory.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
