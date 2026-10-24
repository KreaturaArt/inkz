# TASK-7: ink.json loader — primitives and objects

- Status: Done
- Priority: high
- Labels: layer-1, loader
- Dependencies: —
- Created: 2026-02-23 · Updated: 2026-03-01

## Description

Implement `loadStory(allocator, json_text) !LoadedStory` in `src/runtime/json_loader.zig` using `std.json`.

**Container array parsing rule:** Last element of a JSON array is metadata if it is an object or null. Trailing `null` = no named content. Object may contain `#f` (flags int), `#n` (name string), other keys = named sub-containers. `$r`, `$r1`, `$r2` are shuffle-sequence markers — parse as named containers normally.

**String → RuntimeObject:**
- `"^text"` → `.string("text")` (strip `^`)
- `"\n"` → `.string("\n")`
- `"<>"` → `.glue`
- `"void"` → `.void`
- `"ev"`, `"out"`, `"done"`, `"end"` etc. → `.control_command(ControlCommand.fromString(s).?)`
- `"+"`, `"L^"`, `"?"` etc. → `.native_function(NativeFunction.fromString(s).?)`
- JSON bool → `.bool`; JSON int → `.int`; JSON float → `.float`; JSON array → `.container(parseContainer(...))`

**Object → RuntimeObject:**
- `"->"` → `.divert` (with `is_conditional = "c" key present`, `is_variable = "var" key present`)
- `"->t->"` → `.divert` (push_pop_type = .tunnel)
- `"f()"` → `.divert` (push_pop_type = .function, `is_variable = "var" key present`)
- `"x()"` → `.divert` (external, external_args from `"exArgs"`)
- `"*"` → `.choice_point`
- `"VAR="` → `.variable_assignment` (global)
- `"temp="` → `.variable_assignment` (temp, is_global=false)
- `"VAR?"` → `.variable_reference`
- `"CNT?"` → `.variable_reference` with path_for_count set
- `"^->"` → `.divert_target`
- `"^var"` → `.variable_pointer`
- `"list"` → `.void` (stub — replaced in TASK-31b)

Note: Container path assignment is a separate task (TASK-7b).

Tests:
- Load `misc/hello_world.ink.json`: root has 2 content items (inner container + `.control_command(.done)`); inner container has `.string("Hello world")` at index 0
- Load `evaluation/arithmetic.ink.json`: first 4 items are `.eval_start`, `.int(2)`, `.int(3)`, `.native_function(.multiply)`
- Load `diverts/basic_tunnel.ink.json`: root `named_content.get("f")` is non-null
- Load `lists/list_basic_operations.ink.json`: raw `listDefs` JSON has key `"list"` with 5 entries

## Acceptance Criteria
- [x] hello_world.ink.json loads with correct container structure
- [x] All primitive RuntimeObject types parsed from JSON strings
- [x] All object RuntimeObject types (divert, choice_point, variable_*) parsed correctly
- [x] named_content parsed from trailing object in arrays
- [x] null terminator handled correctly
- [x] listDefs raw JSON accessible on LoadedStory

## Implementation Notes

Implementation complete in src/runtime/json_loader.zig. All JSON parsing done (primitives, objects, container array rules, named_content from trailing object). AC #1-5 verified by tests 14-16. AC #6 (explicit listDefs test loading lists/list_basic_operations.ink.json) not yet written — needed before marking Done.

AC #6 completed: added test 'loadStory list_basic_operations listDefs' to json_loader.zig. Verifies list_defs_json is an object, has key "list", that entry has 5 items, and spot-checks a=1 and e=5.
