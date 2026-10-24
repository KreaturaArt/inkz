# TASK-147.3: P7.3 Explicit-stack parser core:

- Status: To Do
- Priority: medium
- Labels: dod, compiler, parser
- Dependencies: TASK-147.0 (parser spike), TASK-147.2 (AST)
- Parent: TASK-147
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P7.3 in `docs/DODMigrationPlan.md` §6 (Phase 7).

state stack, scratch stack, `marker`/`wrap`, gas counter, `parse_depth_max`.

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] 10k-deep nesting yields a diagnostic, not a crash; the progress invariant is tested.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
