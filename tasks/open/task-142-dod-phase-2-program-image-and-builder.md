# TASK-142: DOD Phase 2: Program image and builder

- Status: To Do
- Priority: high
- Labels: dod, core, program
- Dependencies: TASK-141 (core primitives)
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Phase 2 of the DOD migration plan (`docs/DODMigrationPlan.md` §6, Phase 2). This parent task tracks its subtasks; see the plan for architecture (§4), engineering rules (§3) and decisions (§5).

## Acceptance Criteria
- [ ] TASK-142.1 done: `Opcode`, `Instruction` and operand encodings,
- [ ] TASK-142.2 done: `ContainerInfo` SoA and the named table
- [ ] TASK-142.3 done: `ProgramBuilder`
- [ ] TASK-142.4 done: Path and hash tables
- [ ] TASK-142.5 done: Globals, lists and externals tables
- [ ] TASK-142.6 done: `program.dump(writer)`
- [ ] `zig build lint` passes on all new code of this phase.

## Implementation Notes

## Final Summary
