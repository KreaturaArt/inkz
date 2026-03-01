---
id: TASK-25
title: Function call (f()) and return (~ret)
status: Done
assignee: []
created_date: '2026-02-23 19:43'
updated_date: '2026-03-01 17:31'
labels:
  - layer-5
  - diverts
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement function call and return in `src/runtime/callstack.zig` and `src/runtime/story.zig`.

- `.divert` with `push_pop_type == .function`: save current pointer as `previous_pointer`, push new `.function` Element onto callstack, jump to target container at index 0
- `.control_command(.pop_function)` (`~ret`): pop `.function` element; resume at `previous_pointer`
- `.void`: push `.void` to eval stack (used when function returns nothing — consumed by caller's `pop_eval_stack`)

Tests:
- `evaluation/factorial_recursive.ink.json` → `"120\n"` (5! = 120; exercises recursion)
- `evaluation/evaluating_ink_functions_from_game.ink.json` → verify output matches reference (determine expected before implementing)
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 factorial_recursive.ink.json → "120\n"
- [x] #2 Function call pushes new callstack frame
- [x] #3 ~ret pops frame and resumes at saved pointer
- [x] #4 void object pushed to eval stack on function entry when no return value
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented in src/runtime/story.zig. f() divert saves current pointer to Thread.previous_pointer and pushes .function Element. ~ret (pop_function) pops the frame and restores previous_pointer. Key fix: trailing \"\\n\" objects are trimmed from output_stream after pop_function (Ink compiles conditional blocks in pure functions as structural newlines). Verified by test 30 (Story factorial recursive → "120\n").
<!-- SECTION:NOTES:END -->
