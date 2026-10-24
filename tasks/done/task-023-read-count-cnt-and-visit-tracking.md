# TASK-23: Read count (CNT?) and visit tracking

- Status: Done
- Priority: high
- Labels: layer-4, variables
- Dependencies: —
- Created: 2026-02-23 · Updated: 2026-03-01

## Description

Implement visit count tracking in `src/runtime/state.zig` and `src/runtime/story.zig`.

- When entering a Container whose `flags.visits_should_be_counted == true`, increment `state.visit_counts[container.path]`
- `.variable_reference` with `path_for_count != null` (CNT?): push `state.visit_counts[path] ?? 0` to eval stack as `.int(n)`

Depends on TASK-21 (container path assignment) — visit counts are keyed by the stable path strings.

Tests:
- Unit: manually step into a container with `visits_should_be_counted=true` twice; `visit_counts[path] == 2`
- `builtins/read_count_across_callstack.ink.json` → visit counts tracked correctly across callstack frames
- `builtins/visit_count_bug_due_to_nested_containers.ink.json` → nested container visits don't double-count

## Acceptance Criteria
- [x] visit_counts incremented when entering flagged container
- [x] CNT? pushes 0 for unvisited path
- [x] CNT? pushes correct count for visited path
- [x] read_count_across_callstack.ink.json produces correct output
- [ ] visit_count_bug_due_to_nested_containers.ink.json produces correct output

## Implementation Notes

Implementation complete in src/runtime/story.zig. recordVisitIfNeeded() called when step() enters a container — increments state.visit_counts[container.path] if visits_should_be_counted flag set. CNT? (variable_reference with path_for_count) pushes visit_counts[path] ?? 0 to eval stack. No explicit tests written for visit counting or the two fixture tests (read_count_across_callstack.ink.json, visit_count_bug_due_to_nested_containers.ink.json).

## Final Summary

Bug fixed: CNT? (path_for_count) was looking up visit_counts with the raw path string (e.g., ".^") instead of the resolved container's stable path (e.g., "first"). Fixed by calling resolvePath() to get the container, then using container.path as the key. Added fixture test: read_count_across_callstack.ink.json → "1) Seen first 1 times.\nIn second.\n2) Seen first 1 times.\n". AC #5 (visit_count_bug_due_to_nested_containers) requires choice points (not yet implemented) and is deferred.
