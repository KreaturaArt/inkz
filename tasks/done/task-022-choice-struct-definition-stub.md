# TASK-22: Choice struct definition (stub)

- Status: Done
- Priority: high
- Labels: layer-2, choices
- Dependencies: —
- Created: 2026-02-23 · Updated: 2026-03-01

## Description

Define `Choice` struct in `src/runtime/choices.zig` (no processing logic yet — that is TASK-23).

```zig
pub const Choice = struct {
    text: []const u8,
    source_path: []const u8,
    target_path: Path,
    tags: [][]const u8,
    index: u32,
    original_thread_index: u32,
};
```

**Rationale:** `StoryState` (TASK-10) holds `std.ArrayList(Choice)`. The struct must be defined before the state layer to break the forward dependency. Processing logic (building Choice from eval stack) lives in TASK-23.

Tests:
- A `Choice` can be created with all fields and all fields are accessible
- A `[]Choice` slice can have elements accessed by index
- `Choice.index` field holds the correct value after construction

## Acceptance Criteria
- [x] Choice struct compiles and all fields are accessible
- [x] Can create an array of Choice values
- [x] No processing logic included (deferred to TASK-23)

## Implementation Notes

Implemented in src/runtime/choices.zig. Fields: text, source_path, target_path ([]const u8, not Path — simpler for later resolution), tags, index, original_thread_index. Verified by test 18 (runtime.choices.test.Choice struct).
