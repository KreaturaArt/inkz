---
id: TASK-33
title: Turn tracking (turn / turns / choiceCnt)
status: To Do
assignee: []
created_date: '2026-02-23 19:44'
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
- [ ] #3 turn_indices updated when entering flagged container
- [ ] #4 turns_since returns -1 for never-visited path
<!-- AC:END -->
