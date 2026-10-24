# TASK-140.9: P0.9 Fuzz and simulation harness

- Status: To Do
- Priority: high
- Labels: dod, tooling, testing
- Dependencies: —
- Parent: TASK-140
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P0.9 in `docs/DODMigrationPlan.md` §6 (Phase 0).

- `zig build fuzz` targets: tokenizer, parser, JSON loader, save load, and the save/load round trip.
- `tools/simulate.zig` is a VOPR-style deterministic simulator. From a seed, it plays every fixture with:
  - random choices
  - random save/load points
  - random flow switches
  - random `evaluate_function` calls
  - random `set_variable` calls
  - an optional "compact before every allocation" mode
  It runs `State.verify()` after every `cont()`.

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] The harness runs (targeting the old runtime first) and is reproducible by seed.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
