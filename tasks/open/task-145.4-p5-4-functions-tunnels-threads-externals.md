# TASK-145.4: P5.4 Functions, tunnels, threads, externals

- Status: To Do
- Priority: high
- Labels: dod, runtime, vm
- Dependencies: TASK-144 (runtime state), TASK-140.12 (heuristic report)
- Parent: TASK-145
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P5.4 in `docs/DODMigrationPlan.md` §6 (Phase 5).

(index table, arguments as a stack view, fallbacks, `lookahead_safe`).

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] Ported tests; zero allocations; a non-lookahead-safe external is not called during lookahead (ground truth).
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
