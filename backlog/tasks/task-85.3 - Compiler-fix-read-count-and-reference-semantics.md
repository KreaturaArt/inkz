---
id: TASK-85.3
title: 'Compiler: fix read-count and reference semantics'
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
Fix compiler semantics for pass-by-reference, variable pointers, and read/visit count generation. Current failing fixtures include factorial_by_reference, nested_pass_by_reference, variable_pointer_ref_from_knot, read_count_dot_separated_path, visit_count_bug_due_to_nested_containers, and gather_read_count_with_initial_sequence.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Reference and pointer fixtures pass compileAndRun
- [ ] #2 Read-count and visit-count fixtures pass compileAndRun
- [ ] #3 No regressions in existing evaluation/variables/builtins coverage
<!-- AC:END -->
