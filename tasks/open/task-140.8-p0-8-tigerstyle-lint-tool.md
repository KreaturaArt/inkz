# TASK-140.8: P0.8 TigerStyle lint tool

- Status: To Do
- Priority: high
- Labels: dod, tooling, testing
- Dependencies: —
- Parent: TASK-140
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P0.8 in `docs/DODMigrationPlan.md` §6 (Phase 0).

(`tools/lint.zig`, `zig build lint`). It checks:
- function length ≤ 70 lines, with allowlist entries for `vm.run` and the tokenizer state machine (D10)
- line length ≤ 100 columns
- no recursion: a name-based call-graph cycle check using `std.zig.Ast` over `src/`, with `// lint: not-recursive <reason>` suppressions for false positives, plus a per-directory allowlist so old code can be grandfathered until it is deleted
- no `usize` struct fields
- snake_case file names
- an assertion-density report (asserts per function) that fails new modules averaging below 2

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] The lint passes on `src/core/` from day one.
- [ ] A tests-for-the-linter suite shows each rule firing on sample inputs, including a suppressed false positive.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
