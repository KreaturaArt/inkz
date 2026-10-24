# TASK-145.7: P5.7 Observers,

- Status: To Do
- Priority: high
- Labels: dod, runtime, vm
- Dependencies: TASK-144 (runtime state), TASK-140.12 (heuristic report)
- Parent: TASK-145
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P5.7 in `docs/DODMigrationPlan.md` §6 (Phase 5).

queued per `cont()` and batched.

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] Each observer fires once per variable per `cont()`, after output.
- [ ] `set_variable` outside `cont()` fires immediately.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
