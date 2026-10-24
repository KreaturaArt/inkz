# TASK-6: Path type

- Status: Done
- Priority: high
- Labels: layer-1, core-types
- Dependencies: —
- Created: 2026-02-23 · Updated: 2026-03-01

## Description

Implement `PathComponent = union(enum){ name: []const u8, index: u32, parent }` and `Path = struct{ components: []PathComponent, is_relative: bool }` in `src/runtime/path.zig`. `Path.fromString(s)` parses dot-separated paths.

Tests:
- Path.fromString("0.g-0") → [{index:0}, {name:"g-0"}], absolute
- Path.fromString(".^.1") → [{parent}, {index:1}], relative
- Path.fromString("f") → [{name:"f"}], absolute
- Round-trip: path.toString(alloc) matches input

## Acceptance Criteria
- [x] Path.fromString parses absolute and relative paths correctly
- [x] Parent component parsed from ^
- [x] Round-trip toString matches input

## Implementation Notes

Implemented in src/runtime/path.zig. toString uses a stack-allocated ArrayList to avoid std.ArrayList.writer() (removed in 0.16-dev). Verified by tests 6-10 (5 Path tests all pass).
