# TASK-81: Compiler parser + codegen: sequences & alternatives

- Status: Done
- Priority: high
- Labels: compiler, parser, codegen
- Dependencies: TASK-80
- Created: 2026-03-08 · Updated: 2026-04-05

## Description

Add inline `{a|b|c}` alternative blocks with all sequence types.

**Parser additions**:
- Default (stopping) sequence: `{a|b|c}` — stops at last option after exhausting
- Cycle: `{&a|b|c}` — wraps back to first after last
- Once-only: `{!a|b|c}` — shows blank after exhausting all options
- Shuffle: `{~a|b|c}` — randomised order
- Sequence options can contain: plain text, inline expressions, nested sequences, inline conditionals
- Empty options `|` (blank branch) are valid

**Codegen**:
- Sequence emits: `"ev"` + `"seq"` (sequence_shuffle_index) + `"/ev"` + conditional diverts to each branch container
- Each branch is a named child container (`b`, `b0`, `b1`, etc. or indexed)
- Cycle flag encoded in sequence type; shuffle uses random seed mechanism
- Once-only: last branch is empty container
- Convergence point after all branches (via `"nop"` or position in parent)
- Sequence containers flagged with `count_at_start_only` and `visits_should_be_counted`

Reference: Read `test/fixture/original/runtime/sequences/` fixtures + compiled JSON before implementing. The exact container layout for sequences is non-trivial — study at least two compiled examples.

## Acceptance Criteria
- [x] compileAndRun passes for all test/fixture/original/runtime/sequences/ fixtures
- [x] zig build test passes

## Final Summary

Inline and block sequences (stopping, cycle, once-only, shuffle) implemented. Tests for inline stopping/cycle sequences, block sequences, leading-newline sequences, and empty sequence content all pass. 414/414 tests pass.
