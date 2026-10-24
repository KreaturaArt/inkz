# TASK-74: Compiler parser: basic flow (text, knots, diverts, VAR)

- Status: Done
- Priority: high
- Labels: compiler, parser
- Dependencies: TASK-73
- Created: 2026-03-08 · Updated: 2026-03-08

## Description

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

## Acceptance Criteria
- [x] Parses test/fixture/original/runtime/misc/hello_world.ink into correct Parsed.Story (root_content has one TextLine)
- [x] Parses test/fixture/original/runtime/knots/ fixtures: knot names and content captured correctly
- [x] Parses VAR declarations into global_decls with correct name and literal value
- [x] zig build test passes

## Final Summary

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
