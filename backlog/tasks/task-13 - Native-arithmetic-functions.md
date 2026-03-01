---
id: TASK-13
title: Native arithmetic functions
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
Implement callNativeFunction in src/runtime/evaluation.zig. +, -, *, /, % for int/int, int/float, float/float. Unary negate. Type coercion. Division by zero error.

Tests: arithmetic.ink.json → "36\n2\n3\n2\n2.333333\n8\n8\n"
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 arithmetic.ink.json produces correct 7-line output
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented in src/runtime/evaluation.zig (callNativeFunction). Takes explicit allocator parameter (required for string concat). Int×int → int, float×float → float, int×float → float (coercion). DivisionByZero error on r==0. Float formatting uses 7 significant figures (not 7 decimal places). Verified by test 27 (Story arithmetic → "36\n2\n3\n2\n2.333333\n8\n8\n").
<!-- SECTION:NOTES:END -->
