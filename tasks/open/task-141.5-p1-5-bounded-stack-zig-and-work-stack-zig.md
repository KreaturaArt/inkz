# TASK-141.5: P1.5 `bounded_stack.zig` and `work_stack.zig`

- Status: To Do
- Priority: high
- Labels: dod, core
- Dependencies: TASK-140.2 (build steps), TASK-140.8 (lint), TASK-140.13 (test conventions)
- Parent: TASK-141
- Created: 2026-10-24 · Updated: 2026-11-11

## Description

Plan item P1.5 in `docs/DODMigrationPlan.md` §6 (Phase 1).

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] Overflow returns an error
- [ ] `truncate` restores the previous length
- [ ] `check()` reports a corrupted length (D20).
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
