# TASK-146.3: P6.3 Public API (D5, D8, §4.7)

- Status: To Do
- Priority: high
- Labels: dod, runtime, save, api
- Dependencies: TASK-146.1, TASK-146.2 (save/load)
- Parent: TASK-146
- Created: 2026-10-24 · Updated: 2026-11-11

## Description

Plan item P6.3 in `docs/DODMigrationPlan.md` §6 (Phase 6).

- In-place `story.init(gpa, program, options)` and `story.init_from_json`.
- snake_case methods; `Story.Options{ limits }`; `cont_alloc`; `get_variable`/`set_variable`.
- The public `Value` type is used in callbacks, with a `context` pointer (D22).
- `choose_path_string` options; host events (D22).
- Borrowed-view generation stamps in Debug.
- Callbacks come last in each parameter list.

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] An API test exercises every public method, including every limit error.
- [ ] A stale-view access asserts in Debug.
- [ ] Two stories share one `Program` and run independently.
- [ ] A reentrant mutating call from a callback returns `error.Reentrant`.
- [ ] Each host event fires at ink's point, verified against ground truth.
- [ ] `choose_path_string` without a reset from inside a function is an error.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
