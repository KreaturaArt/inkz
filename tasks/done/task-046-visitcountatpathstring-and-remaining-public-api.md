# TASK-46: visitCountAtPathString and remaining public API

- Status: Done
- Priority: high
- Labels: layer-14, api
- Dependencies: —
- Created: 2026-02-23 · Updated: 2026-03-02

## Description

Implement remaining Story API methods in `src/runtime/story.zig`.

- `visitCountAtPathString(path: []const u8) u32`: parse path, resolve container via `resolvePath`, return `state.visit_counts.get(container.path) orelse 0`
- `currentFlowName() []const u8`: return `current_flow_name`
- `currentFlowIsDefaultFlow() bool`: return `std.mem.eql(u8, current_flow_name, "DEFAULT")`
- `globalTags() [][]const u8`: tags at the very start of the root container (before any non-tag content); equivalent to `tagsForContentAtPath("")`
- `on_error: ?*const fn(message: []const u8, error_type: ErrorType) void` callback field on Story; `ErrorType = enum{ error_, warning }`. Fire via `on_error` for non-fatal conditions (e.g. variable not found) instead of returning an error

Tests:
- After `choosePathString("knot") + cont()`, `visitCountAtPathString("knot") == 1`
- `currentFlowIsDefaultFlow()` returns true initially; false after `switchFlow("other")`
- `globalTags()` on `tags/tags.ink.json` returns `["author: Joe", "title: My Great Story"]`
- Unit: register `on_error`; trigger `variables/warn_variable_not_found_1.ink.json`; callback fires with non-empty warning message

## Acceptance Criteria
- [x] visitCountAtPathString returns 0 for unvisited, correct count for visited
- [x] globalTags returns story-level tags correctly
- [x] currentFlowIsDefaultFlow correct before and after switchFlow
- [x] on_error callback fires for warnings

## Final Summary

Added visitCountAtPathString, currentFlowName, currentFlowIsDefaultFlow, globalTags (with tagsLeadingContent descent), ErrorType enum, and on_error field. globalTags descends into inner containers to find leading tag sequences. Three tests covering visitCount, flow switching, and global tags. All tests pass.
