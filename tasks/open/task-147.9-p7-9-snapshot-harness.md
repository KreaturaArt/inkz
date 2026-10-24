# TASK-147.9: P7.9 Snapshot harness

- Status: To Do
- Priority: medium
- Labels: dod, compiler, parser
- Dependencies: TASK-141 (core primitives)
- Parent: TASK-147
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P7.9 in `docs/DODMigrationPlan.md` §6 (Phase 7).

(`tools/snapshot.zig`, `SNAP_UPDATE=1`).

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] Self-tests.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
