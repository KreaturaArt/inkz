# TASK-149.1: P9.1 Delete the old runtime

- Status: To Do
- Priority: medium
- Labels: dod, cleanup, docs
- Dependencies: TASK-146 (save/load and API)
- Parent: TASK-149
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P9.1 in `docs/DODMigrationPlan.md` §6 (Phase 9).

This also retires the oracle: ground truth plus the stored transcripts remain.

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] Suite green; lint allowlist for runtime removed; no test uses internal fields.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
