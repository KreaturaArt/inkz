# TASK-142.4: P2.4 Path and hash tables

- Status: To Do
- Priority: high
- Labels: dod, core, program
- Dependencies: TASK-141 (core primitives)
- Parent: TASK-142
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P2.4 in `docs/DODMigrationPlan.md` §6 (Phase 2).

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] Every container path and `path_hash` in `crime_scene` matches what ink computes for the inklecate-compiled JSON (ground truth), not only what the old runtime computes.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
