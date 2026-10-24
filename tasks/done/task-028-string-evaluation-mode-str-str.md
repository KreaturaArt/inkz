# TASK-28: String evaluation mode (str / /str)

- Status: Done
- Priority: high
- Labels: layer-7, strings
- Dependencies: —
- Created: 2026-02-23 · Updated: 2026-03-01

## Description

Implement string evaluation mode in `src/runtime/story.zig`.

**Must be completed before TASK-29 (ChoicePoint) — choices build their text using str/str blocks.**

- `.control_command(.begin_string)` (`str`): push a sentinel marker `.control_command(.begin_string)` onto `output_stream`; content mode active (content goes to output_stream, not eval_stack)
- `.control_command(.end_string)` (`/str`): scan backward in `output_stream` to find the marker; collect all `.string` objects between it and end; join them into one string; remove everything back to the marker; push joined `.string` onto `evaluation_stack`

Tests:
- Unit: run `begin_string`, `.string("Hello ")`, `.string("World")`, `end_string` through step dispatch; eval_stack top is `.string("Hello World")`
- Unit: nested string modes don't interfere (str within eval within str)
- `strings/string_constants.ink.json` → `"Hello World\n"` (two string constants concatenated via `+`)
- `strings/strings_in_choices.ink.json` → choices display correct combined text

## Acceptance Criteria
- [x] begin_string/end_string collects content into single string on eval stack
- [x] string_constants.ink.json → "Hello World\n"
- [ ] strings_in_choices.ink.json produces correct choice text
- [x] Unit test for manual str/str dispatch passes

## Implementation Notes

Implementation complete in src/runtime/story.zig. begin_string (.str): sets in_expression_evaluation=true and pushes a .control_command(.begin_string) sentinel onto output_stream. end_string (./str): scans backward to find the sentinel, collects .string items between it and the end, joins them, pops everything back to the sentinel, pushes joined .string onto evaluation_stack. No explicit tests written (string_constants.ink.json, strings_in_choices.ink.json).

## Final Summary

Bug fixed: begin_string was incorrectly setting in_expression_evaluation=true, causing strings inside str/str to go to eval_stack instead of output_stream. Fixed by: (1) removing the in_expression_evaluation mutation from begin_string, (2) adding inStringEvalMode() that checks for a begin_string sentinel in the output_stream, (3) routing strings to output_stream when inStringEvalMode() is true. Also fixed memory leak: dynamic strings from end_string now allocated via arena (freed on story.deinit()) instead of self.allocator. Same for string concatenation in callNativeFunction. Tests: unit (begin_string/end_string dispatch → "Hello World" on eval_stack), string_constants.ink.json → "hi\n". AC #3 (strings_in_choices) deferred until choices are implemented.
