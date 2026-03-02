---
id: TASK-45
title: evaluateFunction
status: Done
assignee: []
created_date: '2026-02-23 19:46'
updated_date: '2026-03-02 17:47'
labels:
  - layer-14
  - api
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement `evaluateFunction` in `src/runtime/story.zig`.

`evaluateFunction(name: []const u8, args: []const RuntimeObject, text_out: ?*std.ArrayList(u8)) !?RuntimeObject`:
1. Save current story state (callstack, output_stream, eval_stack pointers)
2. Push `args` onto eval stack
3. Jump to the named function container
4. Run the step loop (as if calling `cont()`) but capture output separately
5. Pop the return value from eval stack (if any) — this is the function result
6. If `text_out != null`, write captured output text there
7. Restore story state to saved snapshot (so calling `evaluateFunction` has no side-effects on the main story)

Tests:
- `evaluation/evaluating_ink_functions_from_game.ink.json` → `evaluateFunction("returnIntValue", &.{}, null)` returns the expected int; calling it does not corrupt canContinue() or story output
- Unit: call a function that modifies a global variable; after evaluateFunction returns, the global is unchanged (state restored)
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 evaluateFunction returns correct value
- [x] #2 Story state restored after call (no side-effects)
- [x] #3 text_out captures function output text
- [x] #4 evaluating_ink_functions_from_game.ink.json produces correct result
<!-- AC:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Implemented `evaluateFunction` on Story: saves full state via toJson, sets up isolated function call (null return address → loop stops after pop_function), pushes args, runs step loop, captures text output (trailing newlines trimmed by pop_function, matching C# runtime), pops return value, restores full state via loadStateFromJson. Four tests: func1 returns int+text, func2 returns null (void), add(x,y) returns sum, state fully restored. 93/93 tests pass.
<!-- SECTION:FINAL_SUMMARY:END -->
