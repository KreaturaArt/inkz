# TASK-140.1: P0.1 Zig 0.17 compatibility

- Status: To Do
- Priority: high
- Labels: dod, tooling, testing
- Dependencies: —
- Parent: TASK-140
- Created: 2026-10-24 · Updated: 2026-11-11

## Description

Plan item P0.1 in `docs/DODMigrationPlan.md` §6 (Phase 0).

Replace `dupeZ` with `dupeSentinel`, pin `zig` in `mise.toml`, set `minimum_zig_version`, and fix any further 0.17 errors that lazy compilation reveals. Lint does not apply (the lint is built in P0.8).

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] `zig build test` on 0.17.x passes 549/549.
- [ ] Validated by unit tests.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
