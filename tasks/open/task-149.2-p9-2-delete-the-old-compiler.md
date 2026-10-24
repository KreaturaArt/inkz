# TASK-149.2: P9.2 Delete the old compiler

- Status: To Do
- Priority: medium
- Labels: dod, cleanup, docs
- Dependencies: TASK-148 (compiler)
- Parent: TASK-149
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P9.2 in `docs/DODMigrationPlan.md` §6 (Phase 9).

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] Suite green; lint allowlist emptied; all P0.7 skips are gone; the ledger contains no entries caused by old code.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
