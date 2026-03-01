---
id: TASK-32
title: String native functions and builtins
status: In Progress
assignee: []
created_date: '2026-02-23 19:44'
updated_date: '2026-03-01 17:33'
labels:
  - layer-9
  - strings
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Extend `callNativeFunction` in `src/runtime/evaluation.zig` with string and cast operations.

- `add` with two `.string` args → `.string(a ++ b)` (concatenation)
- `equal` / `not_equal` with two `.string` args → byte comparison → `.int(0)` or `.int(1)`
- `int_cast` (`INT()`): `.string` → parse as int; `.float` → truncate to int; `.bool` → 0 or 1
- `float_cast` (`FLOAT()`): `.string` → parse as float; `.int` → convert to float
- `floor`: `.float` → floor as `.int`; `.int` → pass through
- `ceiling`: `.float` → ceiling as `.int`; `.int` → pass through

Tests:
- `strings/string_contains.ink.json` → correct has/hasnt membership output
- `strings/string_type_coercion.ink.json` → int/string/float coercions all correct
- `builtins/floor_ceiling_and_casts.ink.json` → floor/ceiling/cast outputs correct
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 String + string concatenation works
- [ ] #2 INT()/FLOAT() casts work for string and numeric inputs
- [ ] #3 floor/ceiling produce correct int results
- [ ] #4 string_type_coercion.ink.json produces correct output
- [ ] #5 floor_ceiling_and_casts.ink.json produces correct output
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implementation largely complete. String concat (add with two .string args): handled in story.zig handleNativeFunction before delegating to evaluation.zig. String equal/not_equal: handled by valuesEqual in evaluation.zig (std.mem.eql). int_cast/float_cast from string: std.fmt.parseInt/parseFloat in evaluation.zig. floor/ceiling: implemented. No explicit fixture tests written (string_contains.ink.json, string_type_coercion.ink.json, floor_ceiling_and_casts.ink.json).
<!-- SECTION:NOTES:END -->
