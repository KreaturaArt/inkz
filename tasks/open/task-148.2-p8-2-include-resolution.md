# TASK-148.2: P8.2 INCLUDE resolution

- Status: To Do
- Priority: medium
- Labels: dod, compiler, codegen
- Dependencies: TASK-147 (front end), TASK-145 (VM)
- Parent: TASK-148
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P8.2 in `docs/DODMigrationPlan.md` §6 (Phase 8).

into the shared source space (§4.11; Io-based; bounded include depth and file count; cycle detection).

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] The include fixtures pass; an include cycle produces a diagnostic; diagnostics in included files report the right `file:line:column`.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
