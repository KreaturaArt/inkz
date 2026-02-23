---
id: TASK-4
title: RuntimeObject tagged union
status: To Do
assignee: []
created_date: '2026-02-23 19:17'
labels:
  - layer-1
  - core-types
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement `RuntimeObject` tagged union in `src/runtime/value.zig` with variants: void, string, int, float, bool, divert_target, variable_pointer, glue, control_command, native_function, divert, choice_point, variable_assignment, variable_reference, container. ControlCommand enum covers all 20 JSON command strings. NativeFunction covers 16 operators.

Tests:
- Each variant can be created and its tag read
- ControlCommand.fromString("ev") == .eval_start
- ControlCommand.fromString("->->") == .pop_tunnel
- NativeFunction.fromString("+") == .add
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 All RuntimeObject variants can be created and tagged read
- [ ] #2 ControlCommand.fromString maps all 20 JSON strings correctly
- [ ] #3 NativeFunction.fromString maps all 16 operators correctly
<!-- AC:END -->
