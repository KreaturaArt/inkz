# TASK-145.9: P5.9 Randomness

- Status: To Do
- Priority: high
- Labels: dod, runtime, vm
- Dependencies: TASK-144 (runtime state)
- Parent: TASK-145
- Created: 2026-10-24 · Updated: 2026-11-11

## Description

Plan item P5.9 in `docs/DODMigrationPlan.md` §6 (Phase 5).

(S7): `RANDOM`, `LIST_RANDOM`, `SEED_RANDOM` and shuffles, with `previous_random` advancing and `story_seed` fixed, and `Options.random_seed`.

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] Seeded ground-truth cases produce identical sequences.
- [ ] A wrapping `max - min + 1` range matches ink.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
