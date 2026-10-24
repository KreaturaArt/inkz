# TASK-141.2: P1.2 `limits.zig`

- Status: To Do
- Priority: high
- Labels: dod, core
- Dependencies: TASK-140 (lint, build steps)
- Parent: TASK-141
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P1.2 in `docs/DODMigrationPlan.md` §6 (Phase 1).

- `bytes_total()` covers every buffer, including the lookahead snapshot, choice snapshots and flow parking.

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] Comptime relationship asserts compile.
- [ ] Runtime `Limits.verify()` rejects inconsistent options (negative space).
- [ ] A test pins the default `bytes_total()`.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
