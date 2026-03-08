---
id: TASK-82
title: 'Compiler parser + codegen: glue, tags, newlines, strings'
status: To Do
assignee: []
created_date: '2026-03-08 15:47'
labels:
  - compiler
  - parser
  - codegen
dependencies:
  - TASK-81
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
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
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 compileAndRun passes for all test/fixture/original/runtime/glue/ fixtures
- [ ] #2 compileAndRun passes for all test/fixture/original/runtime/tags/ fixtures
- [ ] #3 compileAndRun passes for all test/fixture/original/runtime/newlines/ fixtures
- [ ] #4 compileAndRun passes for all test/fixture/original/runtime/strings/ fixtures
- [ ] #5 zig build test passes
<!-- AC:END -->
