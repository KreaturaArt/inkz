---
id: TASK-8
title: VariablesState
status: To Do
assignee: []
created_date: '2026-02-23 19:18'
labels:
  - layer-2
  - state
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement VariablesState in src/runtime/variables.zig with globals: std.StringHashMap(RuntimeObject). get/set methods, StatePatch support for save/load diff.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 get/set globals work correctly
- [ ] #2 undefined variable returns null
- [ ] #3 overwrite works
<!-- AC:END -->
