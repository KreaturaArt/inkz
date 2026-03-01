---
id: TASK-15
title: Newline handling and glue
status: Done
assignee: []
created_date: '2026-02-23 19:18'
updated_date: '2026-03-01 21:52'
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
- [x] #1 simple_glue.ink.json → "Some content with glue.\n"
- [x] #2 implicit_inline_glue.ink.json produces single-line output
- [x] #3 hello_world.ink.json regression passes
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implementation complete in src/runtime/story.zig. Glue (.glue) handling: when encountered in step(), removes trailing "\n" from output_stream; next string's leading whitespace trimmed via a flag. Exercised by test 31 (basic_tunnel uses glue to join output). AC #3 (hello_world regression) verified by test 25. ACs #1 (simple_glue.ink.json) and #2 (implicit_inline_glue.ink.json) need explicit fixture tests.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Glue handling implemented in collectOutput() in src/runtime/story.zig. When a .glue marker is encountered: trailing "\n" strings are trimmed from the accumulated buffer, and subsequent "\n" strings and chained .glue markers in the output stream are skipped. Implicit function return detection added to the cont() loop (not step()) so it fires when a named function container falls off its end and ptr becomes null. Added output_stream_index_at_push to Element (callstack.zig) to track where each function frame begins writing, enabling trimLeadingNewlinesFromOutputStream to strip structural leading "\n"s from function output. Both explicit (~ret) and implicit return paths trim trailing and leading newlines. ACs #1 (simple_glue → "Some content with glue.\n") and #2 (implicit_inline_glue → "I have five eggs.\n") verified by fixture tests.
<!-- SECTION:FINAL_SUMMARY:END -->
