# TASK-144.5: P4.5 `OutputItem` stream, `string_marks`, function output trimming and line cleaning

- Status: To Do
- Priority: high
- Labels: dod, runtime, state
- Dependencies: TASK-143 (loader), TASK-140.10 (ground truth), TASK-140.11 (neutral test layer)
- Parent: TASK-144
- Created: 2026-10-24 · Updated: 2026-11-11

## Description

Plan item P4.5 in `docs/DODMigrationPlan.md` §6 (Phase 4).

(S10, S11). `end_string` keeps any tags found inside the string region.

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] Every newline/glue/whitespace test passes, including leading newlines inside functions, trailing whitespace on return, `CleanOutputWhitespace` cases and tags inside string evaluation, all from ground truth.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
