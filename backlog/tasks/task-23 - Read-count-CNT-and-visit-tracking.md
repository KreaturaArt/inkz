---
id: TASK-23
title: Read count (CNT?) and visit tracking
status: To Do
assignee: []
created_date: '2026-02-23 19:43'
labels:
  - layer-4
  - variables
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement visit count tracking in `src/runtime/state.zig` and `src/runtime/story.zig`.

- When entering a Container whose `flags.visits_should_be_counted == true`, increment `state.visit_counts[container.path]`
- `.variable_reference` with `path_for_count != null` (CNT?): push `state.visit_counts[path] ?? 0` to eval stack as `.int(n)`

Depends on TASK-21 (container path assignment) — visit counts are keyed by the stable path strings.

Tests:
- Unit: manually step into a container with `visits_should_be_counted=true` twice; `visit_counts[path] == 2`
- `builtins/read_count_across_callstack.ink.json` → visit counts tracked correctly across callstack frames
- `builtins/visit_count_bug_due_to_nested_containers.ink.json` → nested container visits don't double-count
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 visit_counts incremented when entering flagged container
- [ ] #2 CNT? pushes 0 for unvisited path
- [ ] #3 CNT? pushes correct count for visited path
- [ ] #4 read_count_across_callstack.ink.json produces correct output
- [ ] #5 visit_count_bug_due_to_nested_containers.ink.json produces correct output
<!-- AC:END -->
