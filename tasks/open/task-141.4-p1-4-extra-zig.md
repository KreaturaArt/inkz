# TASK-141.4: P1.4 `extra.zig`

- Status: To Do
- Priority: high
- Labels: dod, core
- Dependencies: TASK-140 (lint, build steps)
- Parent: TASK-141
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P1.4 in `docs/DODMigrationPlan.md` §6 (Phase 1).

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] Round trip of a struct with u32, enum, packed and trailing-slice fields.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
