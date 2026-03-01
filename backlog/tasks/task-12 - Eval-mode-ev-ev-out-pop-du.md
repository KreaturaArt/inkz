---
id: TASK-12
title: Eval mode (ev / /ev / out / pop / du)
status: Done
assignee: []
created_date: '2026-02-23 19:18'
updated_date: '2026-03-01 17:31'
labels:
  - layer-3
  - execution
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Track in_expression_evaluation on current Element. Handle eval_start/eval_end, out, pop, du control commands. When in eval mode, push values to evaluation_stack instead of output_stream.

Tests: true.ink.json → "1\n"
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 true.ink.json → 1\n
- [x] #2 eval stack push/pop works correctly
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented in src/runtime/story.zig step() dispatch. eval_start/eval_end toggle in_expression_evaluation on the current Element. Values in eval mode push to evaluation_stack; .output pops top to output_stream; .pop_eval_stack discards; .duplicate copies top. Verified by test 28 (Story boolean true → "1\n").
<!-- SECTION:NOTES:END -->
