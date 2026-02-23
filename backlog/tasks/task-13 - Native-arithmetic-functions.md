---
id: TASK-13
title: Native arithmetic functions
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
Implement callNativeFunction in src/runtime/evaluation.zig. +, -, *, /, % for int/int, int/float, float/float. Unary negate. Type coercion. Division by zero error.

Tests: arithmetic.ink.json → "36\n2\n3\n2\n2.333333\n8\n8\n"
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 arithmetic.ink.json produces correct 7-line output
<!-- AC:END -->
