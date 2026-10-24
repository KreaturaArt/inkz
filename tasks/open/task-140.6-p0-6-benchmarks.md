# TASK-140.6: P0.6 Benchmarks

- Status: To Do
- Priority: high
- Labels: dod, tooling, testing
- Dependencies: —
- Parent: TASK-140
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P0.6 in `docs/DODMigrationPlan.md` §6 (Phase 0).

(`tools/bench.zig`, ReleaseSafe and ReleaseFast).
- Measures load time, `cont()` steps/s, bytes per instruction/node, peak RSS and compile time on `crime_scene` and a generated large story.

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] The baseline for both modes is committed to `docs/benchmarks.md`.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
