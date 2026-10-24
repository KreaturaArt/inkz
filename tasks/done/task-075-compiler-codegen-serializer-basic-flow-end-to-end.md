# TASK-75: Compiler codegen + serializer: basic flow end-to-end

- Status: Done
- Priority: high
- Labels: compiler, codegen, serializer
- Dependencies: TASK-74
- Created: 2026-03-08 · Updated: 2026-03-31

## Description

Implement codegen, serializer, compiler entry point, and test helper. Closes the full pipeline for simple fixtures.

**codegen.zig**: `Parsed.Story` → `CContainer` tree with string paths.
- `CContainer`: `name: ?[]const u8`, `content: []CObject`, `named_children: []NamedChild`, `flags: ContainerFlags`
- `CObject`: mirrors RuntimeObject but all divert/path fields are `[]const u8`
- Root structure: content array + `"done"` sentinel + named knots in last-element dict
- `"global decl"` container for VAR initializers (eval + VAR= + /ev + end)
- Auto-generate `"g-0"` name for implicit done container at root

**serializer.zig**: `CContainer` tree → JSON string.
- Text → `"^text"`, newlines → `"\n"`, `-> END` → `"end"`, `-> DONE` → `"done"`
- Named children in last array element as object with `"#f"` flags and `"#n"` name
- Top level: `{"inkVersion":21,"root":[...],"listDefs":{}}`
- Minimal JSON (no extra whitespace, keys in standard order)

**compiler.zig**: `pub fn compile(allocator, source) ![]u8`

**build.zig**: Add compiler module and tests.

**src/test/compiler_helpers.zig**: `fn compileAndRun(source: []const u8, expected: []const u8) !void` — compiles, loads JSON in runtime via `Story.initFromJson`, runs `story.cont()`, asserts output.

## Acceptance Criteria
- [ ] compileAndRun passes for test/fixture/original/runtime/misc/hello_world.ink (output: "Hello world\n")
- [ ] compileAndRun passes for all misc/ fixtures using only text + knots + simple diverts
- [ ] compileAndRun passes for all knots/ fixtures
- [ ] zig build test passes (240 runtime + new compiler tests)

## Final Summary

Codegen (Parsed.Story → CContainer tree), serializer (CContainer → JSON string), compiler entry point, and e2e test helper compileAndRun. All misc/ and knots/ basic fixtures pass.
