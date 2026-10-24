# TASK-147.0: P7.0 Parser spike (time-boxed, throwaway)

- Status: To Do
- Priority: medium
- Labels: dod, compiler, parser
- Dependencies: TASK-141 (core primitives)
- Parent: TASK-147
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P7.0 in `docs/DODMigrationPlan.md` §6 (Phase 7).

Build the explicit-stack parser skeleton for the hardest nesting: a multi-line `{ cond: … - else: … }` containing a weave with choices whose `[...]` and inline `{…}` nest, plus expressions inside. Use the heterogeneous state stack and recovery.

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] The spike parses 5 hand-picked hard fixtures into the planned node layout.
- [ ] A written go/no-go note records the design adjustments for P7.3.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
