# TASK-144.3: P4.3 StateHeap with sliding mark-compact, triggered when an allocation fails

- Status: To Do
- Priority: high
- Labels: dod, runtime, state
- Dependencies: TASK-143 (loader), TASK-140.10 (ground truth), TASK-140.11 (neutral test layer)
- Parent: TASK-144
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P4.3 in `docs/DODMigrationPlan.md` §6 (Phase 4).

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] Heap use stays bounded over 10k turns of string concatenation.
- [ ] A single `cont()` that builds more garbage than the heap holds succeeds through mid-run compaction.
- [ ] Every root kind listed in §4.5 survives compaction (one test per kind).
- [ ] `error.HeapLimit` is returned on a true overflow.
- [ ] Debug poisoning catches a stale reference (negative test).
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
