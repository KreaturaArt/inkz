---
id: TASK-75
title: 'Compiler codegen + serializer: basic flow end-to-end'
status: Done
assignee: []
created_date: '2026-03-08 15:46'
updated_date: '2026-03-31 18:12'
labels:
  - compiler
  - codegen
  - serializer
dependencies:
  - TASK-74
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
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
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 compileAndRun passes for test/fixture/original/runtime/misc/hello_world.ink (output: "Hello world\n")
- [ ] #2 compileAndRun passes for all misc/ fixtures using only text + knots + simple diverts
- [ ] #3 compileAndRun passes for all knots/ fixtures
- [ ] #4 zig build test passes (240 runtime + new compiler tests)
<!-- AC:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Codegen (Parsed.Story → CContainer tree), serializer (CContainer → JSON string), compiler entry point, and e2e test helper compileAndRun. All misc/ and knots/ basic fixtures pass.
<!-- SECTION:FINAL_SUMMARY:END -->
