---
id: TASK-136
title: Consolidate codegen Gen name-lookup HashMaps into single table
status: To Do
assignee: []
created_date: '2026-05-14 17:42'
labels:
  - compiler
  - performance
  - refactor
dependencies: []
references:
  - 'src/compiler/codegen.zig:78-105'
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
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
<!-- AC:BEGIN -->
- All existing compiler tests pass
- `Gen` struct has ≤ 3 HashMaps total
- No behavioral change (same JSON output)
<!-- SECTION:DESCRIPTION:END -->

- [ ] #1 All existing compiler and runtime tests pass unchanged
- [ ] #2 Gen struct uses ≤ 3 StringHashMapUnmanaged fields
- [ ] #3 No change to compiler JSON output (serializer tests still pass)
<!-- AC:END -->
