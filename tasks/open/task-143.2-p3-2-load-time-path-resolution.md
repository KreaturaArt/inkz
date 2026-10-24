# TASK-143.2: P3.2 Load-time path resolution

- Status: To Do
- Priority: high
- Labels: dod, loader
- Dependencies: TASK-142 (Program and builder)
- Parent: TASK-143
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P3.2 in `docs/DODMigrationPlan.md` §6 (Phase 3).

for every target kind.

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] A scan asserts that no operand refers to a path string, and `verify` passes.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
