# TASK-140.10: P0.10 Ground-truth corpus

- Status: To Do
- Priority: high
- Labels: dod, tooling, testing
- Dependencies: TASK-140.0 (reference harness), TASK-140.11 (test layer), TASK-140.8 (lint)
- Parent: TASK-140
- Created: 2026-10-24 · Updated: 2026-11-11

## Description

Plan item P0.10 in `docs/DODMigrationPlan.md` §6 (Phase 0).

- Each case is `test/ground_truth/<name>.ink`, its inklecate-compiled `<name>.ink.json`, `<name>.actions.zon`, and `<name>.expected`.
- **Action script** (`.actions.zon`): an ordered list of host actions: `cont`, `continue_maximally`, `choose`, `choose_path_string`, `evaluate_function`, `get_variable`/`set_variable`, `observe` (expected notifications), `bind_external` (with scripted returns), `save`, `load`, `switch_flow`, `remove_flow`, `seed`. This covers the many `Tests.cs` cases that use the API.
- **Expected file** (`.expected`): written by the harness (P0.0). It records, after every action, the line text, tags, choices, errors/warnings, observer notifications and requested variables.
- **Sources:**
  - Port the relevant tests from ink's `tests/Tests.cs` at the pinned commit into cases.
  - Generate expectations for the existing compiled fixtures under `test/fixture/original/runtime/` (mirroring the `Tests.cs` categories) with default action scripts.
- The Zig runner (`tools/ground_truth.zig`, a build step) replays action scripts through the P0.11 layer.
- Priority coverage: S1–S11, threads, choices in threads, flows, evaluate-function side effects, glue and newline lookahead, visit and turn counts, shuffles and `RANDOM` with a seed, list ops, int and float edge cases, save/load.

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] A runner executes every case against the old runtime.
- [ ] Results go into the ledger as pass or fail-with-reason, and this becomes the starting state of the ledger.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
