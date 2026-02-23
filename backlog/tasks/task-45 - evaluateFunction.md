---
id: TASK-45
title: evaluateFunction
status: To Do
assignee: []
created_date: '2026-02-23 19:46'
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
- [ ] #1 evaluateFunction returns correct value
- [ ] #2 Story state restored after call (no side-effects)
- [ ] #3 text_out captures function output text
- [ ] #4 evaluating_ink_functions_from_game.ink.json produces correct result
<!-- AC:END -->
