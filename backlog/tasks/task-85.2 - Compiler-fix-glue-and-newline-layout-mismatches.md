---
id: TASK-85.2
title: 'Compiler: fix glue and newline layout mismatches'
status: To Do
assignee: []
created_date: '2026-04-07 09:02'
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
