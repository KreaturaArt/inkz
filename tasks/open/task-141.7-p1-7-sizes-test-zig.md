# TASK-141.7: P1.7 `sizes_test.zig`

- Status: To Do
- Priority: high
- Labels: dod, core
- Dependencies: TASK-140 (lint, build steps)
- Parent: TASK-141
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P1.7 in `docs/DODMigrationPlan.md` §6 (Phase 1).

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] Size asserts for every core type (`Value` 12 B
- [ ] `OutputItem` ≤ 12 B
- [ ] `Frame` ≤ 24 B
- [ ] `Instruction` and `Node` 5 B in SoA
- [ ] `Token` 9 B in SoA).
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
