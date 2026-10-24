# TASK-148: DOD Phase 8: Compiler sema and lowering

- Status: To Do
- Priority: medium
- Labels: dod, compiler, codegen
- Dependencies: TASK-147 (front end), TASK-145 (VM)
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Phase 8 of the DOD migration plan (`docs/DODMigrationPlan.md` §6, Phase 8). This parent task tracks its subtasks; see the plan for architecture (§4), engineering rules (§3) and decisions (§5).

## Acceptance Criteria
- [ ] TASK-148.0 done: Retarget the old codegen to `ProgramBuilder`
- [ ] TASK-148.1 done: Scoped symbol tables and the iterative resolve pass
- [ ] TASK-148.2 done: INCLUDE resolution
- [ ] TASK-148.3 done: Constants and lists
- [ ] TASK-148.4 done: Lowering to `ProgramBuilder`
- [ ] TASK-148.5 done: `ink_json.serialize` and the structural gate
- [ ] TASK-148.6 done: Compiler performance and allocation discipline
- [ ] `zig build lint` passes on all new code of this phase.

## Implementation Notes

## Final Summary
