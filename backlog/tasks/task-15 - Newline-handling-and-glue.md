---
id: TASK-15
title: Newline handling and glue
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
Handle \\n string objects. <> glue: trim trailing newline, suppress leading whitespace. Implement in cont() post-processing.

Tests: simple_glue.ink.json → "Hello World\n"
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 simple_glue.ink.json → Hello World\n
- [ ] #2 No regression on hello_world.ink.json
<!-- AC:END -->
