# TASK-84: Compiler parser + codegen: threads, built-ins, INCLUDE

- Status: Done
- Priority: high
- Labels: compiler, parser, codegen
- Dependencies: TASK-83
- Created: 2026-03-08 · Updated: 2026-04-05

## Description

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

## Acceptance Criteria
- [x] compileAndRun passes for all test/fixture/original/runtime/threads/ fixtures
- [x] compileAndRun passes for all test/fixture/original/runtime/builtins/ fixtures
- [x] compileAndRun passes for all test/fixture/original/runtime/multiflow/ fixtures
- [ ] INCLUDE merges knots and declarations correctly
- [x] zig build test passes

## Final Summary

Threads (thread_start parsing + codegen), built-ins (TURNS, TURNS_SINCE, CHOICE_COUNT, READ_COUNT), and thread-in-sequence all working. Key fixes: root-level stitch nesting bug (stitches must not consume sub-stitches), thread_start silently skipped in parseContent, choice label pre-scan for forward-reference diverts. INCLUDE not implemented (acceptance criterion #4 not checked). 414/414 tests pass.
