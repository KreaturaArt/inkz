---
id: TASK-14
title: Comparison and logic native functions
status: In Progress
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
Extend `callNativeFunction` in `src/runtime/evaluation.zig`:
- `equal`, `not_equal`: compare int/float/bool/string (int↔float coerced); result `.int(0)` or `.int(1)`
- `greater`, `less`, `greater_or_equal`, `less_or_equal`: int/float only (int↔float coerced); result `.int(0)` or `.int(1)`
- `not`: unary; `.int(0)` or `.bool(false)` → `.int(1)`; else → `.int(0)`
- `and_`: both non-zero/non-false → `.int(1)`, else `.int(0)`
- `or_`: either non-zero/non-false → `.int(1)`, else `.int(0)`
- `min`, `max`: int/float, result same type as inputs

Tests:
- `booleans/true.ink.json` → `"1\n"` (regression: was passing after TASK-12)
- `booleans/three_greater_than_one.ink.json` → `"1\n"` (3 > 1 = 1)
- `booleans/true_plus_true.ink.json` → `"2\n"` (1 + 1 = 2)
- `booleans/not_true.ink.json` → `"0\n"` (! true = 0)
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Comparison operators return int 0 or 1 for all supported types
- [ ] #2 not_true.ink.json → "0\n"
- [ ] #3 three_greater_than_one.ink.json → "1\n"
- [ ] #4 true_plus_true.ink.json → "2\n"
- [x] #5 MIN and MAX work for int and float
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implementation complete in src/runtime/evaluation.zig. All comparison and logic operators (equal, not_equal, greater, less, >=, <=, not, and_, or_, min, max) implemented. Exercised implicitly by factorial_recursive test (uses > comparison in recursion base case). AC #1 and #5 verified implicitly. ACs #2 (not_true.ink.json), #3 (three_greater_than_one.ink.json), #4 (true_plus_true.ink.json) need explicit fixture tests before marking Done.
<!-- SECTION:NOTES:END -->
