---
id: TASK-85.8
title: 'Compiler: fix read-count and visit-count semantics'
status: To Do
assignee: []
created_date: '2026-04-07 09:38'
labels:
  - compiler
  - integration
dependencies: []
parent_task_id: TASK-85
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Fix remaining read-count and visit-count generation issues after the reference-semantics work split out of TASK-85.3. Representative failures are runtime/builtins/read_count_dot_separated_path.ink, runtime/builtins/visit_count_bug_due_to_nested_containers.ink, and runtime/sequences/gather_read_count_with_initial_sequence.ink.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 read_count_dot_separated_path.ink passes compileAndRun
- [ ] #2 visit_count_bug_due_to_nested_containers.ink passes compileAndRun
- [ ] #3 gather_read_count_with_initial_sequence.ink passes compileAndRun
<!-- AC:END -->
