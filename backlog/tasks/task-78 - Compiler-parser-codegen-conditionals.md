---
id: TASK-78
title: 'Compiler parser + codegen: conditionals'
status: To Do
assignee: []
created_date: '2026-03-08 15:47'
labels:
  - compiler
  - parser
  - codegen
dependencies:
  - TASK-77
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add all conditional forms: inline, block if/else, and switch.

**Parser additions**:
- Inline conditional: `{cond: true_text | false_text}` — single-line form
- Block conditional: `{ - cond1: content - cond2: content }` — multi-line if/else
- Block without else: `{ cond: content }`
- Switch: `{ value: - case1: content - case2: content }` — value compared to each case
- Nested conditionals (inline within block, block within block)

**Codegen patterns**:
- Inline conditional → `[{"->":".^.b","c":true}, {"b":["^true_text", {"->":"0.X"}, null]}]` + false branch
- Block if/else → conditional divert + branch containers named `b`, `b0`, `b1`, etc.
- Switch → `"du"` (duplicate) before each case comparison so value stays on stack; `"pop"` after last match
- `"nop"` as addressable convergence point after branches
- Branch containers get `{"#f":5}` flags (count_at_start_only + visits_should_be_counted) when needed

Reference: `test/fixture/original/runtime/conditions/` and compiled JSON counterparts. Read one or two compiled fixtures before implementing to verify the exact branch container layout.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 compileAndRun passes for all test/fixture/original/runtime/conditions/ fixtures
- [ ] #2 compileAndRun passes for logic/ fixtures
- [ ] #3 zig build test passes
<!-- AC:END -->
