---
id: TASK-85.4
title: 'Compiler: fix default-choice and choice-state generation'
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
Fix compiler generation for default choices, rollback behavior, and choice container paths. Current failing fixtures include various_default_choices, state_rollback_over_default_choice, temp_usage_in_options, and tunnel_onwards_with_param_default_choice.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 All listed choice/default-choice fixtures pass compileAndRun
- [ ] #2 Choice path generation matches runtime semantics
- [ ] #3 State rollback behavior matches compiled fixture output
<!-- AC:END -->
