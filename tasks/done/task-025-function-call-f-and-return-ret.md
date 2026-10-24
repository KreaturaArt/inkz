# TASK-25: Function call (f()) and return (~ret)

- Status: Done
- Priority: high
- Labels: layer-5, diverts
- Dependencies: —
- Created: 2026-02-23 · Updated: 2026-03-01

## Description

Implement function call and return in `src/runtime/callstack.zig` and `src/runtime/story.zig`.

- `.divert` with `push_pop_type == .function`: save current pointer as `previous_pointer`, push new `.function` Element onto callstack, jump to target container at index 0
- `.control_command(.pop_function)` (`~ret`): pop `.function` element; resume at `previous_pointer`
- `.void`: push `.void` to eval stack (used when function returns nothing — consumed by caller's `pop_eval_stack`)

Tests:
- `evaluation/factorial_recursive.ink.json` → `"120\n"` (5! = 120; exercises recursion)
- `evaluation/evaluating_ink_functions_from_game.ink.json` → verify output matches reference (determine expected before implementing)

## Acceptance Criteria
- [x] factorial_recursive.ink.json → "120\n"
- [x] Function call pushes new callstack frame
- [x] ~ret pops frame and resumes at saved pointer
- [x] void object pushed to eval stack on function entry when no return value

## Implementation Notes

Implemented in src/runtime/story.zig. f() divert saves current pointer to Thread.previous_pointer and pushes .function Element. ~ret (pop_function) pops the frame and restores previous_pointer. Key fix: trailing \"\\n\" objects are trimmed from output_stream after pop_function (Ink compiles conditional blocks in pure functions as structural newlines). Verified by test 30 (Story factorial recursive → "120\n").
