# TASK-140.10: P0.10 Ground-truth corpus

- Status: To Do
- Priority: high
- Labels: dod, tooling, testing
- Dependencies: —
- Parent: TASK-140
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P0.10 in `docs/DODMigrationPlan.md` §6 (Phase 0).

- Pin a commit of the inkle/ink repository and transcribe the relevant runtime tests from `tests/Tests.cs` into `test/ground_truth/<name>.ink` plus `<name>.expected` (line-by-line output, tags, choices, and, where the test checks them, variables, errors and warnings). This happens once. The tool is a `tools/` program where possible, otherwise the transcription is done by hand and reviewed.
- Compile each case with inklecate into `<name>.ink.json`.
- Priority coverage: S1–S9, threads, choices in threads, flows, evaluate-function side effects, glue and newline lookahead, visit and turn counts, shuffles and `RANDOM` with a seed, list ops, int and float edge cases, save/load.

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] A runner executes every case against the old runtime.
- [ ] Results go into the ledger as pass or fail-with-reason, and this becomes the starting state of the ledger.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
