---
id: TASK-26
title: Tunnel (->t->) and conditional divert
status: In Progress
assignee: []
created_date: '2026-02-23 19:43'
updated_date: '2026-03-01 17:32'
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
- [x] #1 basic_tunnel.ink.json → "Hello world\n"
- [x] #2 Tunnel pushes .tunnel frame; ->-> pops it and resumes
- [x] #3 Conditional divert skipped when condition is falsy
- [ ] #4 divert_in_conditional.ink.json produces correct output
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implementation complete in src/runtime/story.zig. ->t-> divert saves pointer to Thread.previous_pointer and pushes .tunnel Element; ->-> (pop_tunnel) pops the frame and restores. Conditional divert (is_conditional=true) pops eval stack and skips divert if falsy. ACs #1-3 verified by test 31 (basic_tunnel.ink.json → "Hello world\n"). AC #4 (divert_in_conditional.ink.json) needs an explicit fixture test.
<!-- SECTION:NOTES:END -->
