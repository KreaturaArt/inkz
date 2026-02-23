---
id: TASK-14
title: Comparison and logic native functions
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
==, !=, >, <, >=, <= for int/float/string/bool (result int 0 or 1). ! unary not. &&, || short-circuit. MIN, MAX for int/float.

Tests: true.ink.json, three_greater_than_one.ink.json, true_plus_true.ink.json, not_false.ink.json
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Comparison operators return 0 or 1 correctly
- [ ] #2 Logic operators work
- [ ] #3 MIN/MAX work for int and float
<!-- AC:END -->
