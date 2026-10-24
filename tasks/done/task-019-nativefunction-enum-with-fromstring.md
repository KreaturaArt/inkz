# TASK-19: NativeFunction enum with fromString

- Status: Done
- Priority: high
- Labels: layer-1, core-types
- Dependencies: —
- Created: 2026-02-23 · Updated: 2026-03-01

## Description

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

## Acceptance Criteria
- [x] All 24 operator strings map to correct variants
- [x] fromString returns null for unknown strings
- [x] fromString("L^") == .list_intersect
- [x] fromString("INT()") == .int_cast
- [x] fromString("?") == .list_has

## Implementation Notes

Implemented in src/runtime/value.zig using std.StaticStringMap. Verified by test 3 (runtime.value.test.NativeFunction.fromString). All 24 operator strings mapped; fromString returns null for unknown strings.
