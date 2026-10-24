# TASK-149.4: P9.4 Final benchmark report

- Status: To Do
- Priority: medium
- Labels: dod, cleanup, docs
- Dependencies: TASK-149.1, TASK-149.2
- Parent: TASK-149
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P9.4 in `docs/DODMigrationPlan.md` §6 (Phase 9).

(ReleaseSafe and ReleaseFast).
---

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] `docs/benchmarks.md` holds the final numbers next to the P0.6 baseline for both ReleaseSafe and ReleaseFast.
- [ ] Every benchmark target in plan §9 is either met or the shortfall is documented with its cause.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
