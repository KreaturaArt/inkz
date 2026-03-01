---
id: TASK-3
title: Build system with test runner
status: Done
assignee: []
created_date: '2026-02-23 19:17'
updated_date: '2026-03-01 17:30'
labels:
  - layer-0
  - infrastructure
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Wire `zig build test` to run a test step. Create stub `root.zig`. Create `helpers.zig` with `loadFixture(comptime path: []const u8) []const u8` that `@embedFile`s a fixture, and a stub `runStory` signature.

Files: `build.zig`, `src/root.zig`, `src/test/helpers.zig`

Tests:
- `zig build test` completes without error
- `helpers.loadFixture("runtime/misc/hello_world.ink.json")` returns non-empty slice
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 zig build test completes without error
- [x] #2 helpers.loadFixture returns non-empty slice for hello_world.ink.json
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Verified by: test 1 (root.test_0) and test 32 (test.helpers.test.loadFixture returns non-empty slice) — both pass. Implemented in build.zig, src/root.zig, src/test/helpers.zig. Uses std.Io.Dir.cwd().readFileAlloc with Io.Threaded pattern from Guidelines.md.
<!-- SECTION:NOTES:END -->
