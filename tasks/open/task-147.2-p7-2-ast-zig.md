# TASK-147.2: P7.2 `ast.zig`:

- Status: To Do
- Priority: medium
- Labels: dod, compiler, parser
- Dependencies: TASK-147.0 (parser spike go/no-go)
- Parent: TASK-147
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P7.2 in `docs/DODMigrationPlan.md` §6 (Phase 7).

5 B nodes, typed views, `to_typed()`, comptime exhaustiveness.

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] Size guards plus the coverage check.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
