---
id: TASK-19
title: NativeFunction enum with fromString
status: Done
assignee: []
created_date: '2026-02-23 19:42'
updated_date: '2026-03-01 17:30'
labels:
  - layer-1
  - core-types
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement `NativeFunction` enum in `src/runtime/value.zig` with `fromString([]const u8) ?NativeFunction`. All 24 operators:

| String | Variant |
|--------|---------|
| `"+"` | `.add` |
| `"-"` | `.subtract` |
| `"*"` | `.multiply` |
| `"/"` | `.divide` |
| `"%"` | `.mod` |
| `"_"` | `.negate` |
| `"=="` | `.equal` |
| `"!="` | `.not_equal` |
| `">"` | `.greater` |
| `"<"` | `.less` |
| `">="` | `.greater_or_equal` |
| `"<="` | `.less_or_equal` |
| `"!"` | `.not` |
| `"&&"` | `.and_` |
| `"||"` | `.or_` |
| `"MIN"` | `.min` |
| `"MAX"` | `.max` |
| `"L^"` | `.list_intersect` |
| `"?"` | `.list_has` |
| `"!?"` | `.list_hasnt` |
| `"INT()"` | `.int_cast` |
| `"FLOAT()"` | `.float_cast` |
| `"FLOOR()"` | `.floor` |
| `"CEILING()"` | `.ceiling` |

Tests:
- `NativeFunction.fromString("+") == .add`
- `NativeFunction.fromString("L^") == .list_intersect`
- `NativeFunction.fromString("?") == .list_has`
- `NativeFunction.fromString("!?") == .list_hasnt`
- `NativeFunction.fromString("INT()") == .int_cast`
- `NativeFunction.fromString("unknown") == null`
- All 24 strings map to non-null variant (exhaustive test)
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 All 24 operator strings map to correct variants
- [x] #2 fromString returns null for unknown strings
- [x] #3 fromString("L^") == .list_intersect
- [x] #4 fromString("INT()") == .int_cast
- [x] #5 fromString("?") == .list_has
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented in src/runtime/value.zig using std.StaticStringMap. Verified by test 3 (runtime.value.test.NativeFunction.fromString). All 24 operator strings mapped; fromString returns null for unknown strings.
<!-- SECTION:NOTES:END -->
