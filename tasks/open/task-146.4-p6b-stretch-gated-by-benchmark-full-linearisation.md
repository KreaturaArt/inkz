# TASK-146.4: P6b (stretch, gated by benchmark) Full linearisation

- Status: To Do
- Priority: low
- Labels: dod, runtime, save, api
- Dependencies: TASK-146.1–146.3 (save/load and API done); optional
- Parent: TASK-146
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P6b in `docs/DODMigrationPlan.md` §6 (Phase 6).

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] Ground truth and oracle still pass (including the visit-count cases) and throughput improves by at least 15%; otherwise the change is dropped.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
