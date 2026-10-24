# TASK-140.2: P0.2 Split build steps

- Status: To Do
- Priority: high
- Labels: dod, tooling, testing
- Dependencies: —
- Parent: TASK-140
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P0.2 in `docs/DODMigrationPlan.md` §6 (Phase 0).

Add `test-runtime`, `test-compiler`, `test-core`, `bench`, `lint`, `fuzz` and `simulate`, plus `-Dtest-filter`. Remove the unused module.

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] Each step runs on its own, and the totals match the full suite.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
