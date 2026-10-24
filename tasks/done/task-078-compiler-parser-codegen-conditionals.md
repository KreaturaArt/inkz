# TASK-78: Compiler parser + codegen: conditionals

- Status: Done
- Priority: high
- Labels: compiler, parser, codegen
- Dependencies: TASK-77
- Created: 2026-03-08 · Updated: 2026-03-31

## Description

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

## Acceptance Criteria
- [ ] compileAndRun passes for all test/fixture/original/runtime/conditions/ fixtures
- [ ] compileAndRun passes for logic/ fixtures
- [ ] zig build test passes

## Final Summary

Inline conditionals, block if/else, switch (dup-based), nested conditionals. All conditions/ fixtures pass. Branch containers named 'b', convergence via nop.
