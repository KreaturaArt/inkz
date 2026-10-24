# TASK-43: StoryState JSON serialization (save / load)

- Status: Done
- Priority: high
- Labels: layer-13, serialization
- Dependencies: —
- Created: 2026-02-23 · Updated: 2026-03-02

## Description

Implement state serialization in `src/runtime/state.zig`.

- `toJson(allocator) ![]u8`: serialize `StoryState` to a JSON string. Must include: callstack threads/elements/pointers, variables_state globals, visit_counts, turn_indices, output_stream items, evaluation_stack items, current_turn_index, story_seed, did_safe_exit
- `loadJson(allocator, json: []const u8) !void`: fully deserialize and restore all state fields from JSON

Tests:
- Serialize freshly-initialized `StoryState` → valid JSON containing keys `"callstackThreads"`, `"variablesState"`, `"visitCounts"`, `"turnIndices"`, `"currentTurnIndex"`, `"storySeed"`
- Unit round-trip: run `misc/hello_world.ink.json` after first `step()` but before `cont()` finishes; serialize state; restore into fresh Story; `cont()` produces the same output as running without interruption
- `lists/list_save_load.ink.json` → story with list variables serializes and restores correctly across save/load boundary

## Acceptance Criteria
- [x] toJson produces valid JSON with all required top-level keys
- [x] loadJson + cont() after mid-run save produces same output as uninterrupted run
- [x] list_save_load.ink.json round-trips correctly
- [x] All state fields (visit_counts, turn_indices, callstack, variables) preserved

## Final Summary

Implemented `toJson` and `loadStateFromJson` on `Story` in `src/runtime/story.zig`. Used `std.Io.Writer.Allocating` (Zig 0.16 API) for dynamic JSON building. Helper functions `writePointerJson` and `writeRtObjJson` handle pointer and runtime object serialization. Load path restores callstack threads/elements, variables, visit/turn counts, eval stack, and output stream. Also fixed `InkList.toDisplayString` sort order to match the C# Ink runtime: sort by `(originName, value)` rather than value-only. 86/86 tests pass.
