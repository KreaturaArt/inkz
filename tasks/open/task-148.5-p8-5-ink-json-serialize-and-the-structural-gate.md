# TASK-148.5: P8.5 `ink_json.serialize` and the structural gate

- Status: To Do
- Priority: medium
- Labels: dod, compiler, codegen
- Dependencies: TASK-148.4 (lowering)
- Parent: TASK-148
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P8.5 in `docs/DODMigrationPlan.md` §6 (Phase 8).

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] `load(serialize(compile(source)))` equals `compile(source)` (verified pair).
- [ ] The exact-JSON test passes.
- [ ] **Every** fixture that has an inklecate-compiled `.json` passes a structural compare (container names, nesting, flags, instruction sequence), with differences only where the ledger lists them.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
