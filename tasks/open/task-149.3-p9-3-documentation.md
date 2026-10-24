# TASK-149.3: P9.3 Documentation

- Status: To Do
- Priority: medium
- Labels: dod, cleanup, docs
- Dependencies: TASK-149.1, TASK-149.2 (old code deleted)
- Parent: TASK-149
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P9.3 in `docs/DODMigrationPlan.md` §6 (Phase 9).

- Rewrite `docs/Architecture.md`.
- Update `docs/Guidelines.md`, merging the TigerStyle rules from §3 with the DOD rules (index newtypes, no pointers in persistent data, `string_pool`, `bounded_stack`, size guards, zero-allocation gate, no recursion, limits, the view-lifetime contract).
- Update `docs/ArchitectureAndDevOverview.md` and `docs/RunningYourInk.md` for D5, D8 and D12, with a migration table.
- Update the project memory and the API conventions.

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] Doc code samples compile in a doctest step.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
