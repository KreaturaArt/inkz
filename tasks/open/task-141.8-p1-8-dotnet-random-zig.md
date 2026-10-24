# TASK-141.8: P1.8 `dotnet_random.zig`

- Status: To Do
- Priority: high
- Labels: dod, core
- Dependencies: TASK-140 (lint, build steps)
- Parent: TASK-141
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P1.8 in `docs/DODMigrationPlan.md` §6 (Phase 1).

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] The first 1000 outputs of `Next()` and `Next(min, max)` match reference sequences from .NET for seeds 0, 1, 42, `maxInt(i32)` and negative seeds.
- [ ] Those sequences are checked in as test data.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
