---
id: TASK-19
title: NativeFunction enum with fromString
status: To Do
assignee: []
created_date: '2026-02-23 19:42'
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
- [ ] #1 All 24 operator strings map to correct variants
- [ ] #2 fromString returns null for unknown strings
- [ ] #3 fromString("L^") == .list_intersect
- [ ] #4 fromString("INT()") == .int_cast
- [ ] #5 fromString("?") == .list_has
<!-- AC:END -->
