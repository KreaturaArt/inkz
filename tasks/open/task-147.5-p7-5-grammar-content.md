# TASK-147.5: P7.5 Grammar, content

- Status: To Do
- Priority: medium
- Labels: dod, compiler, parser
- Dependencies: TASK-141 (core primitives)
- Parent: TASK-147
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P7.5 in `docs/DODMigrationPlan.md` §6 (Phase 7).

(text, glue, tags, inline braces, sequences, diverts, tunnels, threads).

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] Snapshots.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
