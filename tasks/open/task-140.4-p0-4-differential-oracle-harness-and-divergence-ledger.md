# TASK-140.4: P0.4 Differential oracle harness and divergence ledger

- Status: To Do
- Priority: high
- Labels: dod, tooling, testing
- Dependencies: —
- Parent: TASK-140
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P0.4 in `docs/DODMigrationPlan.md` §6 (Phase 0).

Runs old vs new engine (or old vs stored transcripts) turn by turn.
- `test/divergence_ledger.zon` lists every known difference with:
  - fixture and turn
  - kind (S1–S9 or new)
  - reason
  - the ground-truth source that justifies the new behaviour
- The oracle fails on any difference that is not in the ledger, **and on any ledger entry that no longer diverges**, so stale entries get removed.

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] A seeded divergence reports the first differing turn.
- [ ] A ledgered divergence passes.
- [ ] A stale ledger entry fails.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
