# TASK-3: Build system with test runner

- Status: Done
- Priority: high
- Labels: layer-0, infrastructure
- Dependencies: —
- Created: 2026-02-23 · Updated: 2026-03-01

## Description

Wire `zig build test` to run a test step. Create stub `root.zig`. Create `helpers.zig` with `loadFixture(comptime path: []const u8) []const u8` that `@embedFile`s a fixture, and a stub `runStory` signature.

Files: `build.zig`, `src/root.zig`, `src/test/helpers.zig`

Tests:
- `zig build test` completes without error
- `helpers.loadFixture("runtime/misc/hello_world.ink.json")` returns non-empty slice

## Acceptance Criteria
- [x] zig build test completes without error
- [x] helpers.loadFixture returns non-empty slice for hello_world.ink.json

## Implementation Notes

Verified by: test 1 (root.test_0) and test 32 (test.helpers.test.loadFixture returns non-empty slice) — both pass. Implemented in build.zig, src/root.zig, src/test/helpers.zig. Uses std.Io.Dir.cwd().readFileAlloc with Io.Threaded pattern from Guidelines.md.
