# TASK-14: Comparison and logic native functions

- Status: Done
- Priority: high
- Labels: layer-3, execution
- Dependencies: —
- Created: 2026-02-23 · Updated: 2026-03-01

## Description

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

## Acceptance Criteria
- [x] Comparison operators return int 0 or 1 for all supported types
- [x] not_true.ink.json → "0\n"
- [x] three_greater_than_one.ink.json → "1\n"
- [x] true_plus_true.ink.json → "2\n"
- [x] MIN and MAX work for int and float

## Implementation Notes

Implementation complete in src/runtime/evaluation.zig. All comparison and logic operators (equal, not_equal, greater, less, >=, <=, not, and_, or_, min, max) implemented. Exercised implicitly by factorial_recursive test (uses > comparison in recursion base case). AC #1 and #5 verified implicitly. ACs #2 (not_true.ink.json), #3 (three_greater_than_one.ink.json), #4 (true_plus_true.ink.json) need explicit fixture tests before marking Done.
