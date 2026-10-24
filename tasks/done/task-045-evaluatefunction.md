# TASK-45: evaluateFunction

- Status: Done
- Priority: high
- Labels: layer-14, api
- Dependencies: —
- Created: 2026-02-23 · Updated: 2026-03-02

## Description

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

## Acceptance Criteria
- [x] evaluateFunction returns correct value
- [x] Story state restored after call (no side-effects)
- [x] text_out captures function output text
- [x] evaluating_ink_functions_from_game.ink.json produces correct result

## Final Summary

Implemented `evaluateFunction` on Story: saves full state via toJson, sets up isolated function call (null return address → loop stops after pop_function), pushes args, runs step loop, captures text output (trailing newlines trimmed by pop_function, matching C# runtime), pops return value, restores full state via loadStateFromJson. Four tests: func1 returns int+text, func2 returns null (void), add(x,y) returns sum, state fully restored. 93/93 tests pass.
