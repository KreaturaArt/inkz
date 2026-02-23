---
id: TASK-28
title: String evaluation mode (str / /str)
status: To Do
assignee: []
created_date: '2026-02-23 19:43'
labels:
  - layer-7
  - strings
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement string evaluation mode in `src/runtime/story.zig`.

**Must be completed before TASK-29 (ChoicePoint) — choices build their text using str/str blocks.**

- `.control_command(.begin_string)` (`str`): push a sentinel marker `.control_command(.begin_string)` onto `output_stream`; content mode active (content goes to output_stream, not eval_stack)
- `.control_command(.end_string)` (`/str`): scan backward in `output_stream` to find the marker; collect all `.string` objects between it and end; join them into one string; remove everything back to the marker; push joined `.string` onto `evaluation_stack`

Tests:
- Unit: run `begin_string`, `.string("Hello ")`, `.string("World")`, `end_string` through step dispatch; eval_stack top is `.string("Hello World")`
- Unit: nested string modes don't interfere (str within eval within str)
- `strings/string_constants.ink.json` → `"Hello World\n"` (two string constants concatenated via `+`)
- `strings/strings_in_choices.ink.json` → choices display correct combined text
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 begin_string/end_string collects content into single string on eval stack
- [ ] #2 string_constants.ink.json → "Hello World\n"
- [ ] #3 strings_in_choices.ink.json produces correct choice text
- [ ] #4 Unit test for manual str/str dispatch passes
<!-- AC:END -->
