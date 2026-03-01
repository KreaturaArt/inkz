---
id: TASK-11
title: Story struct + text output
status: Done
assignee: []
created_date: '2026-02-23 19:18'
updated_date: '2026-03-01 17:31'
labels:
  - layer-3
  - execution
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement Pointer, Story struct with root/state, step() loop, cont() method, initFromJson/deinit. Basic text output: string objects appended to output_stream, cont() joins and returns text.

Tests: hello_world.ink.json → "Hello world\n", empty.ink.json → ""
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 hello_world.ink.json → Hello world\n
- [x] #2 empty.ink.json → empty string
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented in src/runtime/story.zig. Story.initFromJson loads via json_loader, runs the global decl container, sets initial pointer. step() advances current_pointer and dispatches on RuntimeObject tag. cont() collects output_stream into owned string with value formatting (float uses 7 significant figures). Verified by tests 25-26.
<!-- SECTION:NOTES:END -->
