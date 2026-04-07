---
id: TASK-85.6
title: 'Compiler: fix tunnel and callstack integration cases'
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
Fix remaining tunnel, thread, and callstack-heavy compiler failures. Current fixtures include compare_divert_targets, complex_tunnels, tunnel_vs_thread_behaviour, knot_stitch_gather_counts, knot_thread_interaction_2, and tags_in_seq.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 All listed tunnel/callstack fixtures pass compileAndRun
- [ ] #2 No CannotPop or other tunnel callstack errors remain in this cluster
- [ ] #3 Tunnel and thread behavior matches compiled runtime fixtures
<!-- AC:END -->
