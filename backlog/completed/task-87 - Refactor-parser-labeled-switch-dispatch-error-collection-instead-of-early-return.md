---
id: TASK-87
title: >-
  Refactor parser: labeled-switch dispatch + error collection instead of early
  return
status: Done
assignee: []
created_date: '2026-03-09 17:24'
updated_date: '2026-03-09 18:26'
labels:
  - compiler
  - parser
  - refactor
dependencies:
  - TASK-86
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The sample/Ast.zig shows two patterns worth adopting in src/compiler/parser.zig:

**1. Labeled-switch parser dispatch**
The sample uses `parse: switch (p.cur().tag) { .struct_h => { ... continue :parse p.cur().tag; } }` as the central parser loop. This is more explicit than recursive descent for context-driven grammars — state transitions are visible at a glance rather than hidden in call stacks.

Apply to parseContent(): replace the `while(true) { switch(cur().tag) {} }` loop with a `parse: switch(cur().tag)` that uses `continue :parse` for state transitions. The recursive subparsers (parseKnot, parseTextLine, etc.) can remain as functions since Ink's grammar is genuinely recursive, but the top-level content dispatch benefits from the pattern.

**2. Error collection instead of error propagation for parse errors**
Currently the parser returns `!Parsed.Story` and early-exits on parse errors. The sample returns `error{OutOfMemory}!Ast` — only OOM can fail; parse errors go into `ast.errors: []Error`.

Change parser signature to `error{OutOfMemory}!Parsed.Story` and add a `ParseError` list. When encountering unexpected tokens (wrong knot header, malformed divert, etc.), record the error and skip to the next recoverable position instead of returning an error.

**Acceptance criteria:**
- Parser returns `error{OutOfMemory}!Parsed.Story` (parse errors in a separate errors list)
- parseContent() top-level dispatch uses labeled-switch
- All existing parser tests still pass
- Malformed input produces non-empty errors list rather than crashing
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Parser returns error{OutOfMemory}!Parsed.Story only
- [ ] #2 Parse errors collected in errors []ParseError list
- [ ] #3 parseContent dispatch uses labeled-switch pattern
- [ ] #4 All existing parser tests still pass
- [ ] #5 Test: malformed input produces errors list entry rather than error return
<!-- AC:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Applied sample/Ast.zig idioms to parser: (1) parseContent() rewritten with labeled-switch state machine (continue :parse self.cur().tag); (2) all parser functions return explicit error{OutOfMemory}!T; (3) ParseError/ParseErrorTag added to parsed.zig; (4) errors: []ParseError = &.{} field on Parsed.Story; (5) malformed VAR/CONST records parse errors instead of silently returning null; (6) two tests verify malformed input produces non-empty errors list. 327 tests pass.
<!-- SECTION:FINAL_SUMMARY:END -->
