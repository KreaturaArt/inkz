# TASK-143.1: P3.1 Streaming loader

- Status: To Do
- Priority: high
- Labels: dod, loader
- Dependencies: TASK-142 (Program and builder)
- Parent: TASK-143
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P3.1 in `docs/DODMigrationPlan.md` §6 (Phase 3).

(no `std.json.Value` tree, explicit `WorkStack`, v20 and v21).

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] Every compiled fixture loads, including all 5 v20 fixtures.
- [ ] No allocations after `finish()`.
- [ ] Peak memory is below the old loader's.
- [ ] Fuzz target added.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
