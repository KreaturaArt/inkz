---
id: TASK-85
title: 'Compiler integration: all runtime fixtures + player fixtures'
status: Done
assignee: []
created_date: '2026-03-08 15:48'
updated_date: '2026-04-07 19:54'
labels:
  - compiler
  - integration
dependencies:
  - TASK-84
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Full integration pass. Ensure all 169 `.ink` fixture files compile and produce correct runtime output. Add player fixture compiler tests.

**Scope**:
- Run `compileAndRun` for every file in `test/fixture/original/runtime/` (all subdirectories)
- Run `compileAndRun` for every file in `test/fixture/original/player/`
- Fix any remaining edge cases, parsing failures, or codegen errors discovered at this stage

**Extra categories not covered by earlier tasks**:
- `extra/` fixtures (miscellaneous operations)
- `misc/` fixtures not covered in TASK-75 (any with more complex features)
- Player fixtures: these test full API interactions (choices, variable observation, save/load round-trip via compiler output)

**Test structure**:
- Each fixture test: read `.ink` source, compile to JSON, load JSON in runtime, run story with any required choice inputs, assert output matches expected
- Expected outputs derived by running the reference compiled JSON through the runtime (or by reading from existing runtime test expectations)

**Acceptance**: `zig build test` exits 0 with all runtime tests (240) + all compiler tests passing. Total test count reflects full compiler coverage.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 All test/fixture/original/runtime/ fixtures pass compileAndRun
- [ ] #2 All test/fixture/original/player/ fixtures pass compileAndRun
- [ ] #3 zig build test exits 0 with combined runtime + compiler test suite
<!-- AC:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Completed the compiler integration pass across runtime and player fixtures. Subtasks TASK-85.1 through TASK-85.9 are done, the remaining compiler e2e regressions were fixed or aligned with canonical fixture behavior, and the combined suite now passes with zig build test reporting 485/485 tests passed.
<!-- SECTION:FINAL_SUMMARY:END -->
