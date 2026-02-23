---
id: TASK-26
title: Tunnel (->t->) and conditional divert
status: To Do
assignee: []
created_date: '2026-02-23 19:43'
labels:
  - layer-5
  - diverts
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement tunnel call/return and conditional diverts in `src/runtime/callstack.zig` and `src/runtime/story.zig`.

- `.divert` with `push_pop_type == .tunnel`: save current pointer, push `.tunnel` Element onto callstack, jump to target
- `.control_command(.pop_tunnel)` (`->->`): pop `.tunnel` element, resume at `previous_pointer`
- Conditional divert (`is_conditional == true`): pop a value from eval stack; execute divert only if truthy (non-zero int, non-false bool, non-void); otherwise advance past it

Tests:
- `diverts/basic_tunnel.ink.json` → `"Hello world\n"` (tunnel to "f" + glue)
- `diverts/complex_tunnels.ink.json` → verify output matches reference
- `diverts/divert_in_conditional.ink.json` → divert taken only when condition is true
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 basic_tunnel.ink.json → "Hello world\n"
- [ ] #2 Tunnel pushes .tunnel frame; ->-> pops it and resumes
- [ ] #3 Conditional divert skipped when condition is falsy
- [ ] #4 divert_in_conditional.ink.json produces correct output
<!-- AC:END -->
