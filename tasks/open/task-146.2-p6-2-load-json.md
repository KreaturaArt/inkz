# TASK-146.2: P6.2 `load_json`

- Status: To Do
- Priority: high
- Labels: dod, runtime, save, api
- Dependencies: TASK-145 (VM)
- Parent: TASK-146
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P6.2 in `docs/DODMigrationPlan.md` §6 (Phase 6).

(fixed scratch, validate-then-commit, path resolution through `path.zig`). `verify()` runs after loading (pair assertion with P6.1).

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] Save, load, then continue produces the same transcript as an uninterrupted run, at every turn of every fixture.
- [ ] Every C#-produced save in `test/fixture/saves/` loads and continues identically to C#.
- [ ] A corrupted save leaves the story unchanged.
- [ ] Zero allocations.
- [ ] The fuzz target is added.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
