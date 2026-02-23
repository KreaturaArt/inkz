---
id: TASK-42
title: External function binding
status: To Do
assignee: []
created_date: '2026-02-23 19:45'
labels:
  - layer-12
  - bindings
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement external function dispatch in `src/runtime/story.zig`.

- `ExternalFn = *const fn(args: []const RuntimeObject) ?RuntimeObject`
- `BindOptions = struct{ lookahead_safe: bool = false }`
- `external_functions: std.StringHashMap(ExternalFn)` on Story
- `bindExternalFunction(name: []const u8, fn: ExternalFn, opts: BindOptions) !void`
- In `step()`, `.divert` with external call (`external_args > 0`): pop `external_args` args from eval stack (first arg at top), call bound function, push result or `.void`
- If function not bound and `lookahead_safe == false`: return `error.FunctionNotBound`

Tests:
- `bindings/external_binding.ink.json`: bind a mock `"MULTIPLY"` returning `args[0] * args[1]`; verify output matches reference
- `bindings/game_ink_back_and_forth.ink.json`: interleaved external calls produce correct output
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 external_binding.ink.json: bound function called with correct args and result used
- [ ] #2 game_ink_back_and_forth.ink.json produces correct output
- [ ] #3 Unbound function returns error when not lookahead_safe
- [ ] #4 Function args popped in correct order
<!-- AC:END -->
