# TASK-148.4: P8.4 Lowering to `ProgramBuilder`

- Status: To Do
- Priority: medium
- Labels: dod, compiler, codegen
- Dependencies: TASK-145 (new VM), TASK-148.1–148.3 (resolve, includes, lists), TASK-148.0 (adapter it replaces)
- Parent: TASK-148
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P8.4 in `docs/DODMigrationPlan.md` §6 (Phase 8).

(one iterative pass, backpatch stacks, inklecate-identical container layout). It replaces P8.0's adapter, and the compiler-side reproductions from P5.2 are covered here.

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] All 209 e2e tests pass via compile → Program → new VM.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
