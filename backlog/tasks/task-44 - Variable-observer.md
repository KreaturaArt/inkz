---
id: TASK-44
title: Variable observer
status: To Do
assignee: []
created_date: '2026-02-23 19:46'
labels:
  - layer-14
  - api
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement variable change observers in `src/runtime/story.zig` and `src/runtime/variables.zig`.

- `ObserverFn = *const fn(name: []const u8, value: RuntimeObject) void`
- `observers: std.StringHashMap(ObserverFn)` on Story
- `observeVariable(name: []const u8, fn: ObserverFn) !void`
- When `VariablesState.set` stores a new global value and the story has an observer registered for that name, call the observer with `(name, new_value)`

Tests:
- Unit: register observer for `"x"`; set `x = .int(5)` via story state; observer callback fires exactly once with args `("x", .int(5))`
- Unit: observer not called when a different variable is set
- `bindings/variable_observer.ink.json` → observer fires with correct name and value when variable changes during story execution
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Observer fires when observed variable changes
- [ ] #2 Observer does not fire for unobserved variables
- [ ] #3 variable_observer.ink.json: observer called with correct name and value
- [ ] #4 Multiple observers for different variables all fire independently
<!-- AC:END -->
