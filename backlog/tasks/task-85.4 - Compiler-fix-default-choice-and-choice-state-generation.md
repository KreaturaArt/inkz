---
id: TASK-85.4
title: 'Compiler: fix default-choice and choice-state generation'
status: Done
assignee: []
created_date: '2026-04-07 09:02'
updated_date: '2026-04-07 17:50'
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
- [x] #1 All listed choice/default-choice fixtures pass compileAndRun
- [x] #2 Choice path generation matches runtime semantics
- [x] #3 State rollback behavior matches compiled fixture output
<!-- AC:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Fixed compiler handling for invisible default choices and choice labels within weaves. Fallback choices now preserve their inline/body content without emitting synthetic empty diverts, choice numbering stays stable across gathers so label-based diverts resolve to the right containers, and choice-line parsing now supports inline labels plus tunnel-onwards diverts. Verified with targeted Zig tests for default choice fixtures, rollback behavior, temp-usage-in-options, and tunnel-onwards default-choice cases.
<!-- SECTION:FINAL_SUMMARY:END -->
