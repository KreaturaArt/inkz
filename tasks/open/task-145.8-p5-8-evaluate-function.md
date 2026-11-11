# TASK-145.8: P5.8 `evaluate_function`

- Status: To Do
- Priority: high
- Labels: dod, runtime, vm
- Dependencies: TASK-144 (runtime state)
- Parent: TASK-145
- Created: 2026-10-24 · Updated: 2026-11-11

## Description

Plan item P5.8 in `docs/DODMigrationPlan.md` §6 (Phase 5).

(S1, §4.7) on the live state, through the `cont()` loop.

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] The `evaluating_ink_functions_from_game*` tests pass.
- [ ] A ground-truth case proves that a global changed inside the function persists.
- [ ] The output text matches ink, including line cleaning.
- [ ] A call from inside an external function works up to `evaluate_depth_max`, and other reentrant mutating calls return `error.Reentrant`.
- [ ] Zero allocations.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
