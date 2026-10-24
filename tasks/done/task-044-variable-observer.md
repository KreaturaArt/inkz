# TASK-44: Variable observer

- Status: Done
- Priority: high
- Labels: layer-14, api
- Dependencies: —
- Created: 2026-02-23 · Updated: 2026-03-02

## Description

Implement variable change observers in `src/runtime/story.zig` and `src/runtime/variables.zig`.

- `ObserverFn = *const fn(name: []const u8, value: RuntimeObject) void`
- `observers: std.StringHashMap(ObserverFn)` on Story
- `observeVariable(name: []const u8, fn: ObserverFn) !void`
- When `VariablesState.set` stores a new global value and the story has an observer registered for that name, call the observer with `(name, new_value)`

Tests:
- Unit: register observer for `"x"`; set `x = .int(5)` via story state; observer callback fires exactly once with args `("x", .int(5))`
- Unit: observer not called when a different variable is set
- `bindings/variable_observer.ink.json` → observer fires with correct name and value when variable changes during story execution

## Acceptance Criteria
- [x] Observer fires when observed variable changes
- [x] Observer does not fire for unobserved variables
- [x] variable_observer.ink.json: observer called with correct name and value
- [x] Multiple observers for different variables all fire independently

## Final Summary

Added `ObserverFn` type, `observers` hashmap, `observeVariable()`, and `notifyObservers()` to Story. Observers fire after every global variable set in the `variable_assignment` handler (both re-assignment and new decl paths). Three tests added: fires on observed var, silent on unobserved var, and integration test against variable_observer.ink.json. All 89 tests pass.
