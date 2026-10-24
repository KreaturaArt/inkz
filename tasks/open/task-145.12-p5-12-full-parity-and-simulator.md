# TASK-145.12: P5.12 Full parity and simulator

- Status: To Do
- Priority: high
- Labels: dod, runtime, vm
- Dependencies: TASK-144 (runtime state), TASK-140.12 (heuristic report)
- Parent: TASK-145
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P5.12 in `docs/DODMigrationPlan.md` §6 (Phase 5).

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] Every ground-truth case passes.
- [ ] The oracle passes on every fixture modulo the ledger.
- [ ] All runtime tests run on the new engine through P0.11.
- [ ] `simulate` runs 10k seeds (including compact-always mode) with no verify failure.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
