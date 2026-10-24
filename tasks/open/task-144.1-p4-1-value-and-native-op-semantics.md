# TASK-144.1: P4.1 `Value` and native op semantics

- Status: To Do
- Priority: high
- Labels: dod, runtime, state
- Dependencies: TASK-143 (loader), TASK-140.10 (ground truth), TASK-140.11 (neutral test layer)
- Parent: TASK-144
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P4.1 in `docs/DODMigrationPlan.md` §6 (Phase 4).

(i32 wrapping, f32, C# formatting and conversions).

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] The `evaluation.zig` tests are ported, plus overflow-wrap, division-by-zero, `minInt / -1`, and float-formatting tests taken from ground truth.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
