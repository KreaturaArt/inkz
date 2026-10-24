# TASK-142.1: P2.1 `Opcode`, `Instruction` and operand encodings,

- Status: To Do
- Priority: high
- Labels: dod, core, program
- Dependencies: TASK-141 (core primitives)
- Parent: TASK-142
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P2.1 in `docs/DODMigrationPlan.md` §6 (Phase 2).

with typed `instruction_add`.

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] Encode/decode round trip for every opcode, including the bit-cast i32 and f32 literals; comptime exhaustiveness.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
