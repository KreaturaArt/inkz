---
id: TASK-15
title: Newline handling and glue
status: To Do
assignee: []
created_date: '2026-02-23 19:18'
updated_date: '2026-02-23 19:42'
labels:
  - layer-3
  - execution
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Handle `"\n"` string objects and `<>` glue in `src/runtime/story.zig`.

`"\n"` strings are already appended by the base step() — no special handling needed beyond TASK-11.

Glue (`.glue`): when encountered during output stream collection in `cont()`, trim any trailing whitespace/newlines accumulated so far and skip leading whitespace on the next text segment. Simpler eager approach: in `step()`, when `.glue` is seen, scan backward in output_stream and remove the trailing `"\n"` string if present; set a flag to trim the next string's leading whitespace.

Tests:
- `glue/simple_glue.ink.json` → `"Some content with glue.\n"` (fixture content is `"^Some "`, `<>`, `"\n"`, `"^content"`, `<>`, `"^ with glue."`)
- `glue/implicit_inline_glue.ink.json` → single-line output with no spurious mid-content newline
- `misc/hello_world.ink.json` → still `"Hello world\n"` (regression check)
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 simple_glue.ink.json → "Some content with glue.\n"
- [ ] #2 implicit_inline_glue.ink.json produces single-line output
- [ ] #3 hello_world.ink.json regression passes
<!-- AC:END -->
