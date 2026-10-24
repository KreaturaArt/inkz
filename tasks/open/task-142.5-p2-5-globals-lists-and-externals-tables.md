# TASK-142.5: P2.5 Globals, lists and externals tables

- Status: To Do
- Priority: high
- Labels: dod, core, program
- Dependencies: TASK-141 (core primitives)
- Parent: TASK-142
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P2.5 in `docs/DODMigrationPlan.md` §6 (Phase 2).

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] Tests on a small lists fixture.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
