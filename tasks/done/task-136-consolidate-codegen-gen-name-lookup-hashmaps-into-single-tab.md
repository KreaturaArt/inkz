# TASK-136: Consolidate codegen Gen name-lookup HashMaps into single table

- Status: Done
- Priority: medium
- Labels: compiler, performance, refactor
- Dependencies: —
- References: src/compiler/codegen.zig:78-105
- Created: 2026-05-14 · Updated: 2026-05-17

## Description

## Context

`codegen.zig` `Gen` struct has 9 separate `StringHashMapUnmanaged` fields:
- `const_map` — compile-time constant substitution
- `knot_names` — knot/stitch name set (for CNT? vs VAR? disambiguation)
- `var_names` — declared global VAR names
- `divert_param_names` — divert-target params in current function
- `choice_labels` — label → path for choices
- `gather_label_paths` — label → path for gathers
- `stitch_paths` — stitch bare name → full path
- `external_fn_names` — EXTERNAL declarations (name → param_count)
- `function_params` — function param lists for ref-param lowering

Every name reference in expressions/diverts must check multiple maps in sequence. Each map has its own hash/compare overhead.

## Goal

Consolidate into a single `name_table: StringHashMapUnmanaged(NameEntry)` where `NameEntry` is a discriminated union:

```zig
const NameEntry = union(enum) {
    constant: *const Parsed.Expression,
    knot,
    global_var,
    divert_param,
    choice_label: []const u8,   // path
    gather_label: []const u8,   // path
    stitch_path: []const u8,    // full path
    external_fn: u32,           // param count
    function_params: []const Parsed.Param,
};
```

Single O(1) lookup resolves name to its kind + value.

## Caveats

- `divert_param_names` is scoped per-function (must clear/restore on function boundaries) — needs scope stack or clear on exit
- `stitch_paths` is also scoped per-knot — same issue
- May need a scope mechanism (push/pop entries on enter/exit knot or function)
- Alternative: keep scoped maps separate, merge only the global ones (const_map, knot_names, var_names, external_fn_names, function_params)

## Acceptance Criteria
- All existing compiler tests pass
- `Gen` struct has ≤ 3 HashMaps total
- No behavioral change (same JSON output)

- [x] All existing compiler and runtime tests pass unchanged
- [x] Gen struct uses ≤ 3 StringHashMapUnmanaged fields
- [x] No change to compiler JSON output (serializer tests still pass)

## Final Summary

## What was done

Consolidated 9 `StringHashMapUnmanaged` fields in `Gen` into 1 map + 1 slice.

### New type

Added `NameEntry` struct (before `Gen`) that carries all possible metadata for a name in a single entry — a name can hold multiple roles simultaneously (e.g. a function knot is both `is_knot=true` and `fn_params!=null`):
```zig
const NameEntry = struct {
    is_knot: bool = false,
    is_global_var: bool = false,
    constant: ?*const Parsed.Expression = null,
    choice_path: ?[]const u8 = null,
    gather_path: ?[]const u8 = null,
    stitch_full_path: ?[]const u8 = null,
    external_arg_count: ?u32 = null,
    fn_params: ?[]const Parsed.Param = null,
};
```

### Gen struct changes

Removed 9 fields, added 2:
- `names: StringHashMapUnmanaged(NameEntry)` — replaces `const_map`, `knot_names`, `var_names`, `choice_labels`, `gather_label_paths`, `stitch_paths`, `external_fn_names`, `function_params`
- `current_divert_params: []const Parsed.Param` — replaces `divert_param_names` HashMap; per-knot scope via `self.current_divert_params = knot.params` + `defer self.current_divert_params = &.{}` in `genKnot()`

### New helpers

- `putName(key) !*NameEntry` — get-or-insert with zero-init; `(try self.putName(k)).field = v` replaces all map puts
- `isDivertParam(name) bool` — linear scan over `current_divert_params` (O(1) in practice, params ≤ 5)
- `isVarOrParam(name) bool` — combines `is_global_var` from `names` + `isDivertParam`

### Call sites updated

`generateRoot`, `preScanLabels`, `genKnot`, `genFlowItem` (thread_start arm), `genDivert`, `appendResolvedPlainDivert`, `genWeave` (label registration), `genChoice` (label registration), `genExpr` (var_ref and call arms).

All 549 tests pass. JSON output unchanged (serializer tests still pass).
