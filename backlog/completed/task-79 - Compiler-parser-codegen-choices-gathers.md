---
id: TASK-79
title: 'Compiler parser + codegen: choices & gathers'
status: Done
assignee: []
created_date: '2026-03-08 15:47'
updated_date: '2026-04-05 08:09'
labels:
  - compiler
  - parser
  - codegen
dependencies:
  - TASK-78
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add choice points, choice content, gathers, and nested choice weaves.

**Parser additions**:
- Once-only choice: `* text` and sticky choice: `+ text`
- Choice text components: `shown text [hidden text] after text` (three parts)
- Choice condition: `* {cond} text` — condition precedes display text
- Fallback choice: `* ->` (invisible default, no display text, auto-chosen)
- Gathers: `-` convergence point and `- (label)` named gather
- Nested choices: `* *`, `* * *` — depth by counting leading `*`/`+` markers
- Choice diverts within choice content

**Codegen**:
- Each choice generates a ChoicePoint `{"*":"path.to.c-N","flg":F}` and a named child container `c-N`
- Flags (bitfield): `0x1` has_condition, `0x2` has_start_content, `0x4` has_choice_only_content, `0x8` invisible_default, `0x10` once_only
- Choice container contains: optional start-content, optional choice-only-content, post-choice content, divert to gather
- Choice container path uses relative path from parent: `.^.c-0`
- Gathers become inline containers (or just a position in the enclosing container)
- Nested choices: inner choices are within the outer choice's container; paths reflect nesting depth

Reference: Read `test/fixture/original/runtime/choices/basic_choice.ink` + compiled JSON before implementing.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 compileAndRun passes for all test/fixture/original/runtime/choices/ fixtures
- [x] #2 compileAndRun passes for all test/fixture/original/runtime/weaves/ fixtures
- [x] #3 zig build test passes
<!-- AC:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Implemented in the same session as TASK-80/82/83 (git: "(complete) TASK-79/80/82/83"). Choices, gathers, nested weaves, fallback choices, conditional choices, sticky choices, and choice labels all working. 414/414 tests pass.
<!-- SECTION:FINAL_SUMMARY:END -->
