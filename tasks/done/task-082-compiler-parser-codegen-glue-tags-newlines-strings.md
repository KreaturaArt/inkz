# TASK-82: Compiler parser + codegen: glue, tags, newlines, strings

- Status: Done
- Priority: high
- Labels: compiler, parser, codegen
- Dependencies: TASK-81
- Created: 2026-03-08 · Updated: 2026-04-05

## Description

Add glue operators, tag emission, newline suppression rules, and string evaluation mode.

**Glue**:
- `<>` in source → emit `"<>"` object in container content
- Glue at end of line suppresses the trailing `"\n"`
- Glue at start of line suppresses the leading `"\n"` from the previous line
- `<>` inline within text splits the text string around it

**Tags**:
- `# tag_name` at end of a content line → emit via string eval: `"str"` `"^tag_name"` `"/str"` `"tag"` `"/tag"`
- Multiple tags on one line: emit each tag in sequence
- Tags on choices are stored differently (in choice flags or separate container)

**Newlines**:
- Every content line emits exactly one `"\n"` at the end
- Blank lines in source are collapsed (do not emit extra `"\n"`)
- Lines with only a divert do not emit a `"\n"`
- Glue `<>` adjacent to line boundaries suppresses the `"\n"`

**String evaluation mode**:
- `~ x = "{expr} text {expr2}"` — right-hand side is a string expression
- Emit: `"str"` + [string content as text + inline eval] + `"/str"` → result pushed as string value
- Used in variable assignment when RHS contains `{...}` inside quotes

Reference: Read `test/fixture/original/runtime/glue/`, `tags/`, `newlines/`, `strings/` + compiled JSON. Newline handling is subtle — study the compiled output carefully.

## Acceptance Criteria
- [x] compileAndRun passes for all test/fixture/original/runtime/glue/ fixtures
- [x] compileAndRun passes for all test/fixture/original/runtime/tags/ fixtures
- [x] compileAndRun passes for all test/fixture/original/runtime/newlines/ fixtures
- [x] compileAndRun passes for all test/fixture/original/runtime/strings/ fixtures
- [x] zig build test passes

## Final Summary

Implemented in the same session as TASK-79/80/83 (git: "(complete) TASK-79/80/82/83"). Glue, tags, newline consistency, string constants, string contains operator all working. 414/414 tests pass.
