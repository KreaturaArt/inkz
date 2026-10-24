# TASK-141.9: P1.9 `path.zig`

- Status: To Do
- Priority: high
- Labels: dod, core
- Dependencies: TASK-140 (lint, build steps)
- Parent: TASK-141
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P1.9 in `docs/DODMigrationPlan.md` §6 (Phase 1).

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] Parses and resolves absolute paths, relative paths, `^` and numeric components against a test container table.
- [ ] Rejects malformed paths with a named error.
- [ ] Zero allocations.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
