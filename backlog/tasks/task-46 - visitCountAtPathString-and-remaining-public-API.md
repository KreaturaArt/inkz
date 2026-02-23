---
id: TASK-46
title: visitCountAtPathString and remaining public API
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
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 visitCountAtPathString returns 0 for unvisited, correct count for visited
- [ ] #2 globalTags returns story-level tags correctly
- [ ] #3 currentFlowIsDefaultFlow correct before and after switchFlow
- [ ] #4 on_error callback fires for warnings
<!-- AC:END -->
