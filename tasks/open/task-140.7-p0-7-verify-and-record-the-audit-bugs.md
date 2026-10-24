# TASK-140.7: P0.7 Verify and record the audit bugs

- Status: To Do
- Priority: high
- Labels: dod, tooling, testing
- Dependencies: —
- Parent: TASK-140
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P0.7 in `docs/DODMigrationPlan.md` §6 (Phase 0).

Each becomes a failing test, skipped with a task id. Zero-debt rule: all must be fixed by P9.
- Runtime:
  - `loadStateFromJson` keeps keys that point into freed memory
  - divert, divert-target and variable-pointer values are serialized as `null`
  - saved strings are truncated at 2048 bytes
  - choices, flows, tags and the seed are not saved
  - `story_seed` never advances
  - variable lookup walks every frame
  - `aliveFlowNames` doesn't compile
  - the 33rd temp is undefined behaviour
  - the semantic divergences S1–S8 (§1.1), each with a minimal reproduction and the expected ink output
- Compiler:
  - label names collide globally across knots
  - `temp_names` is never reset
  - INCLUDE is unresolved
  - list auto-numbering is wrong
  - `compile()` ignores errors

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] Every runtime and compiler audit bug listed above has a failing test, marked skipped with the id of the task that will fix it.
- [ ] Each divergence S1–S8 (plan §1.1) has a minimal reproduction with the expected ink output, marked skipped with its fixing task id.
- [ ] A test lists all skipped tests with their task ids, so none can be forgotten before P9.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
