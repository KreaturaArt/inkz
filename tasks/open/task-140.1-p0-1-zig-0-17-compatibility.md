# TASK-140.1: P0.1 Zig 0.17 compatibility

- Status: To Do
- Priority: high
- Labels: dod, tooling, testing
- Dependencies: —
- Parent: TASK-140
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P0.1 in `docs/DODMigrationPlan.md` §6 (Phase 0).

Replace `dupeZ` and bump `build.zig.zon`.

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] `zig build test` on 0.17.0 passes 549/549.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
