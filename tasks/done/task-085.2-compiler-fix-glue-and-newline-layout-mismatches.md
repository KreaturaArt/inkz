# TASK-85.2: Compiler: fix glue and newline layout mismatches

- Status: Done
- Priority: medium
- Labels: compiler, integration
- Dependencies: —
- Parent: TASK-85
- Created: 2026-04-07 · Updated: 2026-04-07

## Description

Fix output layout mismatches where compiler JSON produces incorrect newline or glue behavior. Current representative failure is runtime/logic/multiline_logic_with_glue.ink.

## Acceptance Criteria
- [ ] multiline_logic_with_glue.ink passes compileAndRun
- [ ] Output matches compiled runtime fixture semantics for newline/glue interaction

## Implementation Notes

Adjusted runtime glue output assembly so glue can collapse structural whitespace-plus-newline boundaries down to a single visible space.

Verified full suite moved from 461 pass / 24 fail to 462 pass / 23 fail and cleared logic/multiline_logic_with_glue.ink.

## Final Summary

Fixed the multiline glue/newline integration bug by teaching runtime glue collection to collapse whitespace-plus-newline boundaries to a single space. This cleared the multiline logic glue fixture and moved the suite to 462/485 passing.
