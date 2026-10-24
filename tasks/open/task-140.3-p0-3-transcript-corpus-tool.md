# TASK-140.3: P0.3 Transcript corpus tool

- Status: To Do
- Priority: high
- Labels: dod, tooling, testing
- Dependencies: —
- Parent: TASK-140
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Plan item P0.3 in `docs/DODMigrationPlan.md` §6 (Phase 0).

(`tools/transcript.zig`).
- Runs every compiled fixture with a deterministic choice policy (a seeded choice index sequence), a **turn cap** (`transcript_turns_max`) and a step cap.
- Writes `*.transcript` files recording every `cont()` result with its tags, the choices per turn, and the final variables.
- Line-level records allow comparison with the line-based new runtime. For the old engine, its turn output is split at newlines.

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] A test regenerates the transcripts and the diff is empty.
- [ ] A looping story stops at the cap with a recorded marker.
- [ ] Validated by unit tests; `zig build lint` passes on the new code.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
