# TASK-12: Eval mode (ev / /ev / out / pop / du)

- Status: Done
- Priority: high
- Labels: layer-3, execution
- Dependencies: —
- Created: 2026-02-23 · Updated: 2026-03-01

## Description

Track in_expression_evaluation on current Element. Handle eval_start/eval_end, out, pop, du control commands. When in eval mode, push values to evaluation_stack instead of output_stream.

Tests: true.ink.json → "1\n"

## Acceptance Criteria
- [x] true.ink.json → 1\n
- [x] eval stack push/pop works correctly

## Implementation Notes

Implemented in src/runtime/story.zig step() dispatch. eval_start/eval_end toggle in_expression_evaluation on the current Element. Values in eval mode push to evaluation_stack; .output pops top to output_stream; .pop_eval_stack discards; .duplicate copies top. Verified by test 28 (Story boolean true → "1\n").
