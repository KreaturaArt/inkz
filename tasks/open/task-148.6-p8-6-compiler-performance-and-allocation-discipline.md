# TASK-148.6: P8.6 Compiler performance and allocation discipline

- Status: To Do
- Priority: medium
- Labels: dod, compiler, codegen
- Dependencies: TASK-147 (front end), TASK-145 (VM)
- Parent: TASK-148
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P8.6 in `docs/DODMigrationPlan.md` §6 (Phase 8).

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] The benchmark shows at least 2× less memory than baseline.
- [ ] The compile arena is sized from the source length and retries at most `compile_retries_max` times.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
