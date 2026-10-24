# TASK-15: Newline handling and glue

- Status: Done
- Priority: high
- Labels: layer-3, execution
- Dependencies: —
- Created: 2026-02-23 · Updated: 2026-03-01

## Description

Handle `"\n"` string objects and `<>` glue in `src/runtime/story.zig`.

`"\n"` strings are already appended by the base step() — no special handling needed beyond TASK-11.

Glue (`.glue`): when encountered during output stream collection in `cont()`, trim any trailing whitespace/newlines accumulated so far and skip leading whitespace on the next text segment. Simpler eager approach: in `step()`, when `.glue` is seen, scan backward in output_stream and remove the trailing `"\n"` string if present; set a flag to trim the next string's leading whitespace.

Tests:
- `glue/simple_glue.ink.json` → `"Some content with glue.\n"` (fixture content is `"^Some "`, `<>`, `"\n"`, `"^content"`, `<>`, `"^ with glue."`)
- `glue/implicit_inline_glue.ink.json` → single-line output with no spurious mid-content newline
- `misc/hello_world.ink.json` → still `"Hello world\n"` (regression check)

## Acceptance Criteria
- [x] simple_glue.ink.json → "Some content with glue.\n"
- [x] implicit_inline_glue.ink.json produces single-line output
- [x] hello_world.ink.json regression passes

## Implementation Notes

Implementation complete in src/runtime/story.zig. Glue (.glue) handling: when encountered in step(), removes trailing "\n" from output_stream; next string's leading whitespace trimmed via a flag. Exercised by test 31 (basic_tunnel uses glue to join output). AC #3 (hello_world regression) verified by test 25. ACs #1 (simple_glue.ink.json) and #2 (implicit_inline_glue.ink.json) need explicit fixture tests.

## Final Summary

Glue handling implemented in collectOutput() in src/runtime/story.zig. When a .glue marker is encountered: trailing "\n" strings are trimmed from the accumulated buffer, and subsequent "\n" strings and chained .glue markers in the output stream are skipped. Implicit function return detection added to the cont() loop (not step()) so it fires when a named function container falls off its end and ptr becomes null. Added output_stream_index_at_push to Element (callstack.zig) to track where each function frame begins writing, enabling trimLeadingNewlinesFromOutputStream to strip structural leading "\n"s from function output. Both explicit (~ret) and implicit return paths trim trailing and leading newlines. ACs #1 (simple_glue → "Some content with glue.\n") and #2 (implicit_inline_glue → "I have five eggs.\n") verified by fixture tests.
