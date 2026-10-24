# TASK-147: DOD Phase 7: Compiler front end

- Status: To Do
- Priority: medium
- Labels: dod, compiler, parser
- Dependencies: TASK-141 (core primitives)
- Created: 2026-10-24 · Updated: 2026-10-24

## Description

Phase 7 of the DOD migration plan (`docs/DODMigrationPlan.md` §6, Phase 7). This parent task tracks its subtasks; see the plan for architecture (§4), engineering rules (§3) and decisions (§5).

## Acceptance Criteria
- [ ] TASK-147.0 done: Parser spike (time-boxed, throwaway)
- [ ] TASK-147.1 done: Mode-aware tokenizer
- [ ] TASK-147.2 done: `ast.zig`:
- [ ] TASK-147.3 done: Explicit-stack parser core:
- [ ] TASK-147.4 done: Grammar, top level
- [ ] TASK-147.5 done: Grammar, content
- [ ] TASK-147.6 done: Grammar, weave
- [ ] TASK-147.7 done: Grammar, logic and expressions
- [ ] TASK-147.8 done: Resilience and diagnostics
- [ ] TASK-147.9 done: Snapshot harness
- [ ] TASK-147.10 done: Port the 51 parser shape tests
- [ ] `zig build lint` passes on all new code of this phase.

## Implementation Notes

## Final Summary
