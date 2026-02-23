---
id: TASK-17
title: Temporary variables and callstack scoping
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
temp= stores in currentElement().temporary_variables. VAR? resolution searches temporaries up callstack first then globals. Pop discards temporaries.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Temp var found in current frame
- [ ] #2 After pop temp vars discarded
- [ ] #3 Lookup falls through to globals
<!-- AC:END -->
