# TASK-140.11: P0.11 Engine-neutral test layer

- Status: To Do
- Priority: high
- Labels: dod, tooling, testing
- Dependencies: —
- Parent: TASK-140
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P0.11 in `docs/DODMigrationPlan.md` §6 (Phase 0).

(`test/harness.zig`).
- `run(story_source_or_json) -> Session`, `expect_line`, `expect_lines_until_choice`, `expect_choices`, `choose`, `expect_variable`, `expect_error`, `save`/`load`.
- The layer is implemented for both engines. The old engine adapter splits turn output into lines.
- Runtime tests are migrated onto the layer **before** P4, so they move once and run against both engines.

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] The migrated tests pass on the old engine.
- [ ] The share of runtime tests that still use internal fields is reported, and the target is zero before P9.1.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
