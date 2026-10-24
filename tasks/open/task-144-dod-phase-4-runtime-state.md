# TASK-144: DOD Phase 4: Runtime state

- Status: To Do
- Priority: high
- Labels: dod, runtime, state
- Dependencies: TASK-143 (loader), TASK-140.10 (ground truth), TASK-140.11 (neutral test layer)
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Phase 4 of the DOD migration plan (`docs/DODMigrationPlan.md` §6, Phase 4). This parent task tracks its subtasks; see the plan for architecture (§4), engineering rules (§3) and decisions (§5).

## Acceptance Criteria
- [ ] TASK-144.1 done: `Value` and native op semantics
- [ ] TASK-144.2 done: List slab bitsets and all list builtins
- [ ] TASK-144.3 done: StateHeap with sliding mark-compact, triggered when an allocation fails
- [ ] TASK-144.4 done: Flat frames, threads and temps; fork by range copy
- [ ] TASK-144.5 done: `OutputItem` stream and `string_marks`
- [ ] TASK-144.6 done: Choices SoA with tag ranges and the real thread index
- [ ] TASK-144.7 done: Choice thread snapshot area
- [ ] TASK-144.8 done: Flows with parking
- [ ] TASK-144.9 done: Lookahead snapshot and undo log
- [ ] TASK-144.10 done: Errors and warnings lists
- [ ] TASK-144.11 done: `State.verify()`
- [ ] TASK-144.12 done: Memory budget
- [ ] `zig build lint` passes on all new code of this phase.

## Implementation Notes

## Final Summary
