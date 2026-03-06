---
id: TASK-53
title: 'Tests: runtime/diverts — remaining 11 fixtures'
status: Done
assignee: []
created_date: '2026-03-02 20:23'
updated_date: '2026-03-06 10:43'
labels:
  - tests
  - diverts
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add story-level integration tests for eleven divert fixtures that currently have no test.

Fixtures to cover:
- `runtime/diverts/compare_divert_targets.ink.json`
- `runtime/diverts/divert_in_conditional.ink.json`
- `runtime/diverts/divert_to_weave_points.ink.json`
- `runtime/diverts/done_stops_thread.ink.json`
- `runtime/diverts/path_to_self.ink.json`
- `runtime/diverts/tunnel_onwards_after_tunnel.ink.json`
- `runtime/diverts/tunnel_onwards_divert_after_with_arg.ink.json`
- `runtime/diverts/tunnel_onwards_divert_override.ink.json`
- `runtime/diverts/tunnel_onwards_to_variable_divert_target.ink.json`
- `runtime/diverts/tunnel_onwards_with_param_default_choice.ink.json`
- `runtime/diverts/tunnel_vs_thread_behaviour.ink.json`

Already covered: basic_tunnel, same_line_divert_is_inline, divert_targets_with_parameters, complex_tunnels.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 One test per fixture
- [ ] #2 Output or choice assertions as appropriate
- [ ] #3 All 11 tests pass with `zig build test`
<!-- AC:END -->
