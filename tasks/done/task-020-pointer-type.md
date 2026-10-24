# TASK-20: Pointer type

- Status: Done
- Priority: high
- Labels: layer-1, core-types
- Dependencies: —
- Created: 2026-02-23 · Updated: 2026-03-01

## Description

Implement `Pointer` in `src/runtime/pointer.zig`.

```zig
pub const Pointer = struct {
    container: ?*const Container,
    index: i32,

    pub const null_value: Pointer = .{ .container = null, .index = -1 };
    pub fn isNull(self: Pointer) bool { ... }
    pub fn resolve(self: Pointer) ?*const RuntimeObject { ... }
};
```

`resolve()`: return `&container.content[@intCast(index)]` if container non-null and `index >= 0` and `index < container.content.len`, else return `null`.

**Rationale:** Extracted here (before the CallStack layer) because `Element.current_pointer: Pointer` in TASK-9 creates a forward dependency if Pointer is defined in story.zig.

Tests:
- `Pointer.null_value.isNull() == true`
- `Pointer.null_value.resolve() == null`
- Pointer with valid container and index 0: `isNull() == false`, `resolve()` returns pointer to first content item
- Pointer with out-of-bounds index: `resolve() == null`
- Pointer with null container: `resolve() == null`

## Acceptance Criteria
- [x] null_value.isNull() == true
- [x] null_value.resolve() == null
- [x] Valid pointer resolve() returns correct content item
- [x] Out-of-bounds index resolve() returns null

## Implementation Notes

Implemented in src/runtime/pointer.zig. Note: container field is ?*Container (mutable, not ?*const Container) to support resolvePath and recordVisitIfNeeded which need mutable container access. Verified by tests 11-13 (3 Pointer tests all pass).

Gap found on verification: AC #2 (null_value.resolve() == null) is not tested. The test 'Pointer.null_value' only calls isNull(), never resolve(). The implementation handles it correctly (orelse return null) but there is no assertion. Need to add: try std.testing.expectEqual(@as(?*const RuntimeObject, null), Pointer.null_value.resolve());

Fixed: 'Pointer.null_value' test now also asserts Pointer.null_value.resolve() == null.
