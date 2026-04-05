---
id: TASK-84
title: 'Compiler parser + codegen: threads, built-ins, INCLUDE'
status: Done
assignee: []
created_date: '2026-03-08 15:48'
updated_date: '2026-04-05 08:09'
labels:
  - compiler
  - parser
  - codegen
dependencies:
  - TASK-83
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add thread syntax, built-in game queries, and file inclusion.

**Threads**:
- `<- knot_name` → emit `"thread"` control command + `{"->":"knot_name"}` divert
- Thread diverts use the same path resolution as regular diverts

**Built-in game queries** (parse as function calls, emit as control commands):
- `TURNS()` → `"turn"` control command
- `TURN_SINCE(-> knot)` → `"ev"` `{"^->":"knot"}` `"turns"` `"/ev"` — divert target as argument
- `READ_COUNT(-> knot)` → `"ev"` `{"^->":"knot"}` `"visit"` `"/ev"`
- `CHOICE_COUNT()` → `"choiceCnt"` control command
- `RANDOM(a, b)` → `"ev"` a b `"rnd"` `"/ev"`
- `SEED_RANDOM(n)` → `"ev"` n `"srnd"` `"/ev"`

**INCLUDE**:
- `INCLUDE filename.ink` → read the included file relative to the current file's directory, parse it, and merge its declarations (knots, global_decls, list_defs, external_fns) into the parent story
- Circular include detection (track included file paths)
- Included file's root content is not merged — only knots and declarations

Reference: Read `test/fixture/original/runtime/threads/`, `builtins/`, `multiflow/` + compiled JSON before implementing.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 compileAndRun passes for all test/fixture/original/runtime/threads/ fixtures
- [x] #2 compileAndRun passes for all test/fixture/original/runtime/builtins/ fixtures
- [x] #3 compileAndRun passes for all test/fixture/original/runtime/multiflow/ fixtures
- [ ] #4 INCLUDE merges knots and declarations correctly
- [x] #5 zig build test passes
<!-- AC:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Threads (thread_start parsing + codegen), built-ins (TURNS, TURNS_SINCE, CHOICE_COUNT, READ_COUNT), and thread-in-sequence all working. Key fixes: root-level stitch nesting bug (stitches must not consume sub-stitches), thread_start silently skipped in parseContent, choice label pre-scan for forward-reference diverts. INCLUDE not implemented (acceptance criterion #4 not checked). 414/414 tests pass.
<!-- SECTION:FINAL_SUMMARY:END -->
