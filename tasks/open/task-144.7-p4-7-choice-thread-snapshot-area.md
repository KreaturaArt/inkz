# TASK-144.7: P4.7 Choice thread snapshot area

- Status: To Do
- Priority: high
- Labels: dod, runtime, state
- Dependencies: TASK-143 (loader), TASK-140.10 (ground truth), TASK-140.11 (neutral test layer)
- Parent: TASK-144
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P4.7 in `docs/DODMigrationPlan.md` §6 (Phase 4).

(S5), with sharing of consecutive identical snapshots.

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] A choice generated inside a thread restores that thread when chosen, verified by a ground-truth case; snapshot sharing is verified
- [ ] `choice_snapshot_frames_max` overflow returns its error.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
