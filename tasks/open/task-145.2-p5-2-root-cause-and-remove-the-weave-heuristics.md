# TASK-145.2: P5.2 Root-cause and remove the weave heuristics

- Status: To Do
- Priority: high
- Labels: dod, runtime, vm
- Dependencies: TASK-140.12 (heuristic firing report), TASK-144 (runtime state)
- Parent: TASK-145
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P5.2 in `docs/DODMigrationPlan.md` §6 (Phase 5).

Use the P0.12 report. For each firing, write a minimal reproduction and classify it as a runtime semantic gap (fixed in the VM) or compensation for old-compiler output (recorded for P8.0/P8.4, and not fixed in the old compiler).

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] Every inklecate-compiled reproduction passes on the new VM with no heuristic code.
- [ ] The compiler-side reproductions are linked from P8.4.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
