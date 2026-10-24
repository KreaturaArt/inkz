# TASK-145: DOD Phase 5: VM

- Status: To Do
- Priority: high
- Labels: dod, runtime, vm
- Dependencies: TASK-144 (runtime state), TASK-140.12 (heuristic report)
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Phase 5 of the DOD migration plan (`docs/DODMigrationPlan.md` §6, Phase 5). This parent task tracks its subtasks; see the plan for architecture (§4), engineering rules (§3) and decisions (§5).

## Acceptance Criteria
- [ ] TASK-145.1 done: Labeled-switch `vm.run` with a step budget and `RunResult` signals
- [ ] TASK-145.2 done: Root-cause and remove the weave heuristics
- [ ] TASK-145.3 done: Variables:
- [ ] TASK-145.4 done: Functions, tunnels, threads, externals
- [ ] TASK-145.5 done: Line-based `cont()`
- [ ] TASK-145.6 done: Visit counting on divert
- [ ] TASK-145.7 done: Observers,
- [ ] TASK-145.8 done: `evaluate_function`
- [ ] TASK-145.9 done: Randomness
- [ ] TASK-145.10 done: Errors and warnings
- [ ] TASK-145.11 done: Zero-allocation gate
- [ ] TASK-145.12 done: Full parity and simulator
- [ ] `zig build lint` passes on all new code of this phase.

## Implementation Notes

## Final Summary
