---
id: TASK-16
title: Global variable assignment and reference
status: To Do
assignee: []
created_date: '2026-02-23 19:18'
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
- [ ] #1 VAR= stores value in globals
- [ ] #2 VAR? pushes value to eval stack
- [ ] #3 Global init block runs before content
<!-- AC:END -->
