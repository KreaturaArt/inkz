---
id: TASK-43
title: StoryState JSON serialization (save / load)
status: To Do
assignee: []
created_date: '2026-02-23 19:46'
labels:
  - layer-13
  - serialization
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement state serialization in `src/runtime/state.zig`.

- `toJson(allocator) ![]u8`: serialize `StoryState` to a JSON string. Must include: callstack threads/elements/pointers, variables_state globals, visit_counts, turn_indices, output_stream items, evaluation_stack items, current_turn_index, story_seed, did_safe_exit
- `loadJson(allocator, json: []const u8) !void`: fully deserialize and restore all state fields from JSON

Tests:
- Serialize freshly-initialized `StoryState` → valid JSON containing keys `"callstackThreads"`, `"variablesState"`, `"visitCounts"`, `"turnIndices"`, `"currentTurnIndex"`, `"storySeed"`
- Unit round-trip: run `misc/hello_world.ink.json` after first `step()` but before `cont()` finishes; serialize state; restore into fresh Story; `cont()` produces the same output as running without interruption
- `lists/list_save_load.ink.json` → story with list variables serializes and restores correctly across save/load boundary
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 toJson produces valid JSON with all required top-level keys
- [ ] #2 loadJson + cont() after mid-run save produces same output as uninterrupted run
- [ ] #3 list_save_load.ink.json round-trips correctly
- [ ] #4 All state fields (visit_counts, turn_indices, callstack, variables) preserved
<!-- AC:END -->
