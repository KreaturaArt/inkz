---
id: TASK-85.2
title: 'Compiler: fix glue and newline layout mismatches'
status: Done
assignee: []
created_date: '2026-04-07 09:02'
updated_date: '2026-04-07 09:13'
labels:
  - compiler
  - integration
dependencies: []
parent_task_id: TASK-85
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Fix output layout mismatches where compiler JSON produces incorrect newline or glue behavior. Current representative failure is runtime/logic/multiline_logic_with_glue.ink.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 multiline_logic_with_glue.ink passes compileAndRun
- [ ] #2 Output matches compiled runtime fixture semantics for newline/glue interaction
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Adjusted runtime glue output assembly so glue can collapse structural whitespace-plus-newline boundaries down to a single visible space.

Verified full suite moved from 461 pass / 24 fail to 462 pass / 23 fail and cleared logic/multiline_logic_with_glue.ink.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Fixed the multiline glue/newline integration bug by teaching runtime glue collection to collapse whitespace-plus-newline boundaries to a single space. This cleared the multiline logic glue fixture and moved the suite to 462/485 passing.
<!-- SECTION:FINAL_SUMMARY:END -->
