---
id: TASK-137
title: Eliminate duplicate format spec between serializer.zig and json_loader.zig
status: To Do
assignee: []
created_date: '2026-05-14 17:43'
labels:
  - compiler
  - runtime
  - maintainability
dependencies: []
references:
  - src/compiler/serializer.zig
  - src/runtime/json_loader.zig
priority: low
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
## Context

`serializer.zig` and `json_loader.zig` both hard-code the ink.json wire format, with no shared constants:

- `serializer.zig` writes `{"->":"target"}` for diverts, `{"*":"path","flg":N}` for choices, `{"VAR=":"name"}` for var assigns, etc.
- `json_loader.zig:parseObjectRuntimeObject()` reads the same keys back with matching string literals

Any format change (e.g. adding a new object type) requires updating two files. No compile-time guard catches divergence.

Additionally, `serializer.zig` checks for string prefix `^` to distinguish text from string literals; `json_loader.zig` applies the same `^` prefix check in `parseStringObject()`. Same logic duplicated.

## Goal

Extract a shared `src/ink_format.zig` (or `src/compiler/format.zig`) with `pub const` string keys:

```zig
pub const key_divert = "->";
pub const key_tunnel_divert = "->t->";
pub const key_choice = "*";
pub const key_var_assign = "VAR=";
pub const key_temp_assign = "temp=";
pub const key_var_ref = "VAR?";
pub const key_read_count = "CNT?";
pub const key_flags = "#f";
pub const key_name = "#n";
pub const key_text_prefix = "^";
// etc.
```

Both files import and use these. Format change = one place.

## Acceptance Criteria
<!-- AC:BEGIN -->
- No string literal for ink.json keys appears in both serializer.zig and json_loader.zig
- All existing serializer and json_loader tests pass
- No behavioral change
<!-- SECTION:DESCRIPTION:END -->

- [ ] #1 Shared format constants file exists and is imported by both serializer.zig and json_loader.zig
- [ ] #2 No duplicated ink.json key string literals across serializer.zig and json_loader.zig
- [ ] #3 All existing tests pass
<!-- AC:END -->
