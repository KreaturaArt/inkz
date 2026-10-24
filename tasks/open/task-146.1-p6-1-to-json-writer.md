# TASK-146.1: P6.1 `to_json(writer)`

- Status: To Do
- Priority: high
- Labels: dod, runtime, save, api
- Dependencies: TASK-145 (VM)
- Parent: TASK-146
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P6.1 in `docs/DODMigrationPlan.md` §6 (Phase 6).

(§4.10; streaming, iterative, zero allocation). `State.verify()` runs before saving.

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] The P0.7 save bugs are fixed and their tests un-skipped.
- [ ] The output of a C#-identical state equals the checked-in C# save byte for byte, modulo JSON key order if ink's writer order is not stable (to be checked).
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
