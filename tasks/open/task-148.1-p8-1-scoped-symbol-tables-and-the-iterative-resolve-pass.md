# TASK-148.1: P8.1 Scoped symbol tables and the iterative resolve pass

- Status: To Do
- Priority: medium
- Labels: dod, compiler, codegen
- Dependencies: TASK-147 (front end), TASK-145 (VM)
- Parent: TASK-148
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P8.1 in `docs/DODMigrationPlan.md` §6 (Phase 8).

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] The same label in two knots resolves correctly; temps are scoped; forward references work; unresolved names produce a diagnostic.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
