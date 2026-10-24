# TASK-142.3: P2.3 `ProgramBuilder`

- Status: To Do
- Priority: high
- Labels: dod, core, program
- Dependencies: TASK-141 (core primitives)
- Parent: TASK-142
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P2.3 in `docs/DODMigrationPlan.md` §6 (Phase 2).

with the fixup list and `finish()`, followed by `Program.verify()`.

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] Contiguous nested containers; fixups resolve; unresolved targets produce a diagnostic; a corrupted program fails `verify` (negative space).
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
