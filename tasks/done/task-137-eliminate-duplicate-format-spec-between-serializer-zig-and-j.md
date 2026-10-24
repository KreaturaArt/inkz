# TASK-137: Eliminate duplicate format spec between serializer.zig and json_loader.zig

- Status: Done
- Priority: low
- Labels: compiler, runtime, maintainability
- Dependencies: —
- References: src/compiler/serializer.zig, src/runtime/json_loader.zig
- Created: 2026-05-14 · Updated: 2026-05-17

## Description

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
- No string literal for ink.json keys appears in both serializer.zig and json_loader.zig
- All existing serializer and json_loader tests pass
- No behavioral change

- [x] Shared format constants file exists and is imported by both serializer.zig and json_loader.zig
- [x] No duplicated ink.json key string literals across serializer.zig and json_loader.zig
- [x] All existing tests pass

## Final Summary

New file `src/ink_format.zig` with 20 pub constants covering all ink.json wire-format keys (`key_divert`, `key_tunnel_divert`, `key_var_assign`, `key_meta_name`, `key_meta_flags`, etc.) plus `text_prefix`/`text_prefix_char`. Both `serializer.zig` and `json_loader.zig` import it as `const fmt = @import("../ink_format.zig")` and use the constants throughout. `root.zig` exports the module and adds it to the test block. 549/549 tests pass; JSON output identical.
