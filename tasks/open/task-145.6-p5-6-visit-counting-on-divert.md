# TASK-145.6: P5.6 Visit counting on divert

- Status: To Do
- Priority: high
- Labels: dod, runtime, vm
- Dependencies: TASK-144 (runtime state), TASK-140.12 (heuristic report)
- Parent: TASK-145
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P5.6 in `docs/DODMigrationPlan.md` §6 (Phase 5).

(S3/S4): common-ancestor walk and `count_start_only`.

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] Ground-truth cases for diverts into nested stitches and gathers, `count_start_only`, and turn indices.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
