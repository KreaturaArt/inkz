---
id: TASK-74
title: 'Compiler parser: basic flow (text, knots, diverts, VAR)'
status: Done
assignee: []
created_date: '2026-03-08 15:45'
updated_date: '2026-03-08 16:23'
labels:
  - compiler
  - parser
dependencies:
  - TASK-73
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement `src/compiler/parser.zig` with combinator base layer and basic ink grammar rules.

**Combinator base**:
- `save()` / `restore(saved)` for backtracking
- `oneOrMore(T, rule) ![]T`
- `spaced(rule)`, `expect(token)`, `optional(rule)`

**Grammar rules to implement**:
- Plain text lines (with optional inline glue `<>`)
- Comments: `//` (line), `/* */` (block) — skip silently
- Knot declarations: `=== name ===` and `== name ==`
- Stitch declarations: `= name`
- Simple diverts: `-> target`, `-> END`, `-> DONE`
- Global variable declarations: `VAR name = literal_value`
- Constant declarations: `CONST name = literal_value`
- INCLUDE directives: `INCLUDE filename.ink`

**Output**: `Parsed.Story` struct with root_content, knots, global_decls, constants, includes populated from token stream.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Parses test/fixture/original/runtime/misc/hello_world.ink into correct Parsed.Story (root_content has one TextLine)
- [x] #2 Parses test/fixture/original/runtime/knots/ fixtures: knot names and content captured correctly
- [x] #3 Parses VAR declarations into global_decls with correct name and literal value
- [x] #4 zig build test passes
<!-- AC:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Created src/compiler/parser.zig with recursive-descent parser over a Token slice.

Key components:
- `parse(alloc, src)` public entry: tokenises then parses in one call
- `parseStory()` → root_content + knots + global_decls + constants + includes
- `parseContent()` stops at knot_marker / stitch_marker, dispatches on first token of each line
- `parseKnot()` / `parseStitch()` — captures names, content, and nested stitches
- `parseTextLine()` / `parseDivertLine()` / `parseDivertInline()` — FlowItem production
- `parseVarLine()` / `parseConstLine()` / `parseIncludeLine()` — declaration parsing
- `parseLiteralExpr()` — int, float, bool, quoted string, identifier reference

Seven tests cover all acceptance criteria:
- hello_world.ink → root_content has one TextLine with text "Hello world"
- end_of_content.ink → knot named "test"
- knot_do_not_gather.ink → knot named "knot", root divert to "knot"
- variable_get_set_api.ink → VAR x = 5 parsed as int_lit
- const.ink → CONST c = 5 parsed
- include.ink → two INCLUDE paths captured
- knot_thread_interaction.ink → three knot names
- knot_stitch_gather_counts.ink → VAR inside knot added to global_decls
<!-- SECTION:FINAL_SUMMARY:END -->
