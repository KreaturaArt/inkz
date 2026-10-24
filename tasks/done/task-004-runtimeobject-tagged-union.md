# TASK-4: RuntimeObject tagged union

- Status: Done
- Priority: high
- Labels: layer-1, core-types
- Dependencies: —
- Created: 2026-02-23 · Updated: 2026-03-01

## Description

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

## Acceptance Criteria
- [x] All RuntimeObject variants can be created and their tag read
- [x] Divert struct fields accessible after construction
- [x] choice_point flags byte accessible
- [x] ControlCommand and NativeFunction correctly embedded via TASK-4a/4b

## Implementation Notes

Implemented in src/runtime/value.zig. Container and RuntimeObject are co-located in the same file to resolve the circular import. .list variant uses anyopaque pointer (stub for TASK-37). Verified by test 4 (runtime.value.test.RuntimeObject variants).

Gap found on verification: AC #1 (all variants can be created) is not met by the 'RuntimeObject variants' test, which only constructs .void, .int, .divert, .choice_point (4 of 16). Variants .string, .float, .bool, .glue, .divert_target, .variable_pointer, .control_command, .native_function, .variable_assignment, .variable_reference, .list, .container are created by json_loader tests indirectly, but there is no single comprehensive unit test for all RuntimeObject variants.

Fixed: 'RuntimeObject variants' test now constructs all 15 concrete variants (void, string, int, float, bool, glue, divert_target, variable_pointer, control_command, native_function, divert, choice_point, variable_assignment, variable_reference, container). .list is a *anyopaque stub and is not directly testable until InkList is implemented in TASK-37.
