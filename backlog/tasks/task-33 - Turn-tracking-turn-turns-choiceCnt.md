---
id: TASK-33
title: Turn tracking (turn / turns / choiceCnt)
status: Done
assignee: []
created_date: '2026-02-23 19:44'
updated_date: '2026-03-01 22:51'
labels:
  - layer-8
  - tracking
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement turn-index commands in `src/runtime/state.zig` and `src/runtime/story.zig`.

- `.control_command(.turn_index)` (`turn`): push `state.current_turn_index` to eval stack as `.int`
- `.control_command(.turns_since)` (`turns`): pop a `.divert_target(path)` from eval stack; look up `state.turn_indices[path]`; push `current_turn_index - turn_indices[path]` or `.int(-1)` if path never visited
- `.control_command(.choice_count)` (`choiceCnt`): push `state.current_choices.items.len` as `.int`
- Update `state.turn_indices[container.path] = current_turn_index` when a container with `flags.turn_index_should_be_counted == true` is entered

Tests:
- `builtins/turns.ink.json` → correct turns-since values across multiple turns
- `choices/choice_count.ink.json` → correct choice count in output
- Unit: enter a turn-counted container; `turn_indices[path]` is set to `current_turn_index`
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 turns.ink.json produces correct output
- [ ] #2 choice_count.ink.json produces correct output
- [x] #3 turn_indices updated when entering flagged container
- [x] #4 turns_since returns -1 for never-visited path
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implementation complete in src/runtime/story.zig. turn_index: pushes current_turn_index as .int. turns_since: pops a .divert_target path, looks up turn_indices map, returns (current_turn_index - last_visit) or -1 if never visited. choice_count: pushes current_choices.items.len as .int. turn_indices updated when entering a container with turn_index_should_be_counted flag. No explicit tests written (turns.ink.json, choice_count.ink.json).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Implementation was already complete. Added 3 tests:
1. `turn_indices updated when entering flagged container`: runs variable_divert_target.ink.json (where "here" has #f:3 = visits+turn_index_should_be_counted); asserts turn_indices["here"] == 0 after cont().
2. `turns_since returns -1 for never-visited path`: unit test that pushes a divert_target for an unvisited path onto the eval stack, dispatches turns_since, confirms result is -1.
ACs #1 (turns.ink.json) and #2 (choice_count.ink.json) deferred — both fixtures require choice support (not yet implemented).
<!-- SECTION:FINAL_SUMMARY:END -->
