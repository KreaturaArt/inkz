---
id: TASK-22
title: Choice struct definition (stub)
status: To Do
assignee: []
created_date: '2026-02-23 19:42'
labels:
  - layer-2
  - choices
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
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
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Choice struct compiles and all fields are accessible
- [ ] #2 Can create an array of Choice values
- [ ] #3 No processing logic included (deferred to TASK-23)
<!-- AC:END -->
