---
id: TASK-85.5
title: 'Compiler: fix weave and divert path layout'
status: To Do
assignee: []
created_date: '2026-04-07 09:02'
labels:
  - compiler
  - integration
dependencies: []
parent_task_id: TASK-85
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Fix nested weave container layout and divert path generation. Current failing fixtures include conditional_choice_in_weave, conditional_choice_in_weave_2, unbalanced_weave_indentation, divert_to_weave_points, and extra/list_comparison.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 All listed weave/divert fixtures pass compileAndRun
- [ ] #2 Nested weave choices and gathers resolve to valid runtime paths
- [ ] #3 No DivertTargetNotFound errors in this fixture cluster
<!-- AC:END -->
