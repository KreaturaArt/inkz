---
id: TASK-49
title: 'Tests: runtime/builtins — remaining 8 fixtures'
status: Done
assignee: []
created_date: '2026-03-02 20:23'
updated_date: '2026-03-04 16:24'
labels:
  - tests
  - builtins
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add story-level integration tests for the eight builtin fixtures that currently have no test.

Fixtures to cover:
- `runtime/builtins/read_count_across_threads.ink.json`
- `runtime/builtins/read_count_dot_separated_path.ink.json`
- `runtime/builtins/read_count_variable_target.ink.json`
- `runtime/builtins/turns_since_nested.ink.json`
- `runtime/builtins/turns_since_with_variable_target.ink.json`
- `runtime/builtins/turns.ink.json`
- `runtime/builtins/visit_count_bug_due_to_nested_containers.ink.json`
- `runtime/builtins/visit_counts_when_choosing.ink.json`

Already covered in same category: `floor_ceiling_and_casts`, `read_count_across_callstack`.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 One test per fixture listed above
- [ ] #2 Each test asserts expected output or key properties (e.g. choice-driven stories assert choice count)
- [ ] #3 All tests pass with `zig build test`
<!-- AC:END -->
