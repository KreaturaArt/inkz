# TASK-148.0: P8.0 Retarget the old codegen to `ProgramBuilder`

- Status: To Do
- Priority: medium
- Labels: dod, compiler, codegen
- Dependencies: TASK-142.3 (ProgramBuilder), TASK-145 (new VM)
- Parent: TASK-148
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P8.0 in `docs/DODMigrationPlan.md` §6 (Phase 8).

(D16). This is a thin adapter from `CContainer` to the builder, so the old front end feeds the new VM.

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] All 209 e2e tests pass via the old front end → Program → new VM, with differences only where the ledger lists them.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
