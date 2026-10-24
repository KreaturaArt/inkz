# TASK-13: Native arithmetic functions

- Status: Done
- Priority: high
- Labels: layer-3, execution
- Dependencies: —
- Created: 2026-02-23 · Updated: 2026-03-01

## Description

Implement callNativeFunction in src/runtime/evaluation.zig. +, -, *, /, % for int/int, int/float, float/float. Unary negate. Type coercion. Division by zero error.

Tests: arithmetic.ink.json → "36\n2\n3\n2\n2.333333\n8\n8\n"

## Acceptance Criteria
- [x] arithmetic.ink.json produces correct 7-line output

## Implementation Notes

Implemented in src/runtime/evaluation.zig (callNativeFunction). Takes explicit allocator parameter (required for string concat). Int×int → int, float×float → float, int×float → float (coercion). DivisionByZero error on r==0. Float formatting uses 7 significant figures (not 7 decimal places). Verified by test 27 (Story arithmetic → "36\n2\n3\n2\n2.333333\n8\n8\n").
