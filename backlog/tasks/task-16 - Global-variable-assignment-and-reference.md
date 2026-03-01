---
id: TASK-16
title: Global variable assignment and reference
status: Done
assignee: []
created_date: '2026-02-23 19:18'
updated_date: '2026-03-01 17:31'
labels:
  - layer-4
  - variables
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Handle variable_assignment (VAR=) and variable_reference (VAR?) in step(). Global initialization block. 

Tests: const.ink.json produces correct output
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 VAR= stores value in globals
- [x] #2 VAR? pushes value to eval stack
- [x] #3 Global init block runs before content
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented in src/runtime/story.zig. VAR= pops eval stack and stores in globals; VAR? looks up via resolveVariable (searches temp frames first, then globals). Global decl container (named_content.get("global decl")) is executed at initFromJson time before any content. Verified by test 29 (Story const variable → "5\n").
<!-- SECTION:NOTES:END -->
