---
id: TASK-3
title: Build system with test runner
status: To Do
assignee: []
created_date: '2026-02-23 19:17'
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
- [ ] #1 zig build test completes without error
- [ ] #2 helpers.loadFixture returns non-empty slice for hello_world.ink.json
<!-- AC:END -->
