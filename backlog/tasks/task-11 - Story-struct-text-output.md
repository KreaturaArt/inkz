---
id: TASK-11
title: Story struct + text output
status: To Do
assignee: []
created_date: '2026-02-23 19:18'
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
- [ ] #1 hello_world.ink.json → Hello world\n
- [ ] #2 empty.ink.json → empty string
<!-- AC:END -->
