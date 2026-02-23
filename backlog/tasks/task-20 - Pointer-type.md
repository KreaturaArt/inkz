---
id: TASK-20
title: Pointer type
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
- [ ] #1 null_value.isNull() == true
- [ ] #2 null_value.resolve() == null
- [ ] #3 Valid pointer resolve() returns correct content item
- [ ] #4 Out-of-bounds index resolve() returns null
<!-- AC:END -->
