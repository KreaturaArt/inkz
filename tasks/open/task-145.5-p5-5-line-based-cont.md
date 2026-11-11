# TASK-145.5: P5.5 Line-based `cont()`

- Status: To Do
- Priority: high
- Labels: dod, runtime, vm
- Dependencies: TASK-144 (runtime state)
- Parent: TASK-145
- Created: 2026-10-24 · Updated: 2026-11-11

## Description

Plan item P5.5 in `docs/DODMigrationPlan.md` §6 (Phase 5).

(§4.6, D12) and `continue_maximally`, with invisible defaults, `DONE`/`END` semantics and end-of-content errors.

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] The ground-truth glue and newline cases pass line by line, and tags attach to the correct line, including tags after a newline.
- [ ] The `default_choices`, `fallback_choice_on_thread` and `choice_diverts_to_done` cases pass.
- [ ] Each end-of-content error and warning appears where ink raises it.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
