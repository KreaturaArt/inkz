# TASK-140.12: P0.12 Weave-heuristic instrumentation

- Status: To Do
- Priority: high
- Labels: dod, tooling, testing
- Dependencies: —
- Parent: TASK-140
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P0.12 in `docs/DODMigrationPlan.md` §6 (Phase 0).

Count how often `loopBackGatherTailPeel` and `divertTargetsAncestorOfAnyChoiceSource` fire, separately for inklecate-compiled fixtures and for inkz-compiled stories.

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] A report in `docs/benchmarks.md` lists each fixture where a heuristic fires, split by compiler.
- [ ] P5.2 uses this report to tell runtime gaps from compensation for old-compiler bugs.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
