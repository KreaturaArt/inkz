---
id: TASK-10
title: StoryState
status: To Do
assignee: []
created_date: '2026-02-23 19:18'
labels:
  - layer-2
  - state
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement StoryState in src/runtime/state.zig combining call_stack, output_stream, evaluation_stack, current_choices, variables_state, visit_counts, turn_indices, current_turn_index, story_seed, did_safe_exit. init/deinit.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 StoryState.init creates zero-value defaults
- [ ] #2 deinit cleans up without leaks
<!-- AC:END -->
