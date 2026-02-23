---
id: TASK-12
title: Eval mode (ev / /ev / out / pop / du)
status: To Do
assignee: []
created_date: '2026-02-23 19:18'
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
- [ ] #1 true.ink.json → 1\n
- [ ] #2 eval stack push/pop works correctly
<!-- AC:END -->
