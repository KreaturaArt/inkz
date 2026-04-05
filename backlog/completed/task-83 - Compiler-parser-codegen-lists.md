---
id: TASK-83
title: 'Compiler parser + codegen: lists'
status: Done
assignee: []
created_date: '2026-03-08 15:48'
updated_date: '2026-04-05 08:09'
labels:
  - compiler
  - parser
  - codegen
dependencies:
  - TASK-82
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add LIST declarations, list literals, and list operators.

**Parser additions**:
- `LIST origin_name = item_a, item_b, item_c` — top-level list definition; optional `(item)` marks default value
- List literal in expression: `(item_a, item_b)` → InkList value
- Single item reference: `origin_name.item_a` or bare `item_a` (if unambiguous from context)
- List operators in expressions: `?` (has), `!?` (hasn't), `^` (intersection), `LIST_COUNT()`, `LIST_MIN()`, `LIST_MAX()`, `LIST_ALL()`, `LIST_INVERT()`, `LIST_RANGE()`, `LIST_RANDOM()`, `LIST_VALUE()`
- `+=` / `-=` shorthand for list add/remove

**Codegen**:
- `LIST` definition → populate `"listDefs"` section in JSON: `{"origin_name":{"item_a":1,"item_b":2,...}}`
- List literal → `{"list":{"origin.item":value,...},"origins":["origin"]}` runtime object
- List operators → native function strings: `"?"`, `"!?"`, `"^"`, `"LIST_COUNT"`, `"LIST_MIN"`, `"LIST_MAX"`, `"LIST_ALL"`, `"LIST_INVERT"`, `"LIST_RANGE"`, `"LIST_RANDOM"`, `"LIST_VALUE"`
- `+=` / `-=` → desugar to read + add/subtract + assign

Reference: Read `test/fixture/original/runtime/lists/` + compiled JSON. Check `docs/ink_JSON_runtime_format.md` for listDefs format.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 compileAndRun passes for all test/fixture/original/runtime/lists/ fixtures
- [x] #2 listDefs section in emitted JSON is correct (runtime can look up list definitions)
- [x] #3 zig build test passes
<!-- AC:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Implemented in the same session as TASK-79/80/82 (git: "(complete) TASK-79/80/82/83"). LIST declarations, list literals, list operators, listDefs JSON section, and inline list operations all working. 414/414 tests pass.
<!-- SECTION:FINAL_SUMMARY:END -->
