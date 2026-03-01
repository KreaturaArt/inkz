---
id: TASK-20
title: Pointer type
status: Done
assignee: []
created_date: '2026-02-23 19:42'
updated_date: '2026-03-01 17:43'
labels:
  - layer-1
  - core-types
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
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
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 null_value.isNull() == true
- [x] #2 null_value.resolve() == null
- [x] #3 Valid pointer resolve() returns correct content item
- [x] #4 Out-of-bounds index resolve() returns null
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented in src/runtime/pointer.zig. Note: container field is ?*Container (mutable, not ?*const Container) to support resolvePath and recordVisitIfNeeded which need mutable container access. Verified by tests 11-13 (3 Pointer tests all pass).

Gap found on verification: AC #2 (null_value.resolve() == null) is not tested. The test 'Pointer.null_value' only calls isNull(), never resolve(). The implementation handles it correctly (orelse return null) but there is no assertion. Need to add: try std.testing.expectEqual(@as(?*const RuntimeObject, null), Pointer.null_value.resolve());

Fixed: 'Pointer.null_value' test now also asserts Pointer.null_value.resolve() == null.
<!-- SECTION:NOTES:END -->
