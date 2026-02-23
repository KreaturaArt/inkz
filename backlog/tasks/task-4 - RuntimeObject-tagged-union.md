---
id: TASK-4
title: RuntimeObject tagged union
status: To Do
assignee: []
created_date: '2026-02-23 19:17'
updated_date: '2026-02-23 19:41'
labels:
  - layer-1
  - core-types
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement `RuntimeObject` tagged union in `src/runtime/value.zig`.

**Depends on:** TASK-4a (ControlCommand), TASK-4b (NativeFunction)

**Important — circular import:** `Container.content: []RuntimeObject` and `RuntimeObject.container: *Container` reference each other. Both types must live in the same file (`value.zig`). `ChoicePoint` is defined inline here (not in choices.zig) to avoid circular imports.

Variants:
- `.void`
- `.string([]const u8)`
- `.int(i64)`
- `.float(f64)`
- `.bool(bool)`
- `.glue`
- `.divert_target(Path)`
- `.variable_pointer(struct{ name: []const u8, context_index: i32 })`
- `.control_command(ControlCommand)`
- `.native_function(NativeFunction)`
- `.divert(struct{ target: []const u8, is_variable: bool, is_conditional: bool, push_pop_type: ?PushPopType, external_args: u32 })`
- `.choice_point(struct{ path: []const u8, flags: u8 })`
- `.variable_assignment(struct{ name: []const u8, is_new_decl: bool, is_global: bool })`
- `.variable_reference(struct{ name: []const u8, path_for_count: ?[]const u8 })`
- `.list(anyopaque)` — stub replaced in TASK-31b
- `.container(*Container)`

Tests:
- Each variant can be created and its tag read via `std.meta.activeTag`
- `.divert` with all fields set, read back correctly
- `.choice_point` flags field accessible
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 All RuntimeObject variants can be created and their tag read
- [ ] #2 Divert struct fields accessible after construction
- [ ] #3 choice_point flags byte accessible
- [ ] #4 ControlCommand and NativeFunction correctly embedded via TASK-4a/4b
<!-- AC:END -->
