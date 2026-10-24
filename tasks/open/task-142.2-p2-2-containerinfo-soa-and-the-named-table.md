# TASK-142.2: P2.2 `ContainerInfo` SoA and the named table

- Status: To Do
- Priority: high
- Labels: dod, core, program
- Dependencies: TASK-141 (core primitives)
- Parent: TASK-142
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P2.2 in `docs/DODMigrationPlan.md` §6 (Phase 2).

(with `depth`, and `index_in_parent = none` for named-only containers).

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] Named lookup compares u32s only; out-of-range lookups assert; the depth and parent invariants hold in `verify`.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
