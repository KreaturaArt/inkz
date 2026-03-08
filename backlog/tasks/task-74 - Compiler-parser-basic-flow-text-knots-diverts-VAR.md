---
id: TASK-74
title: 'Compiler parser: basic flow (text, knots, diverts, VAR)'
status: To Do
assignee: []
created_date: '2026-03-08 15:45'
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
- [ ] #1 Parses test/fixture/original/runtime/misc/hello_world.ink into correct Parsed.Story (root_content has one TextLine)
- [ ] #2 Parses test/fixture/original/runtime/knots/ fixtures: knot names and content captured correctly
- [ ] #3 Parses VAR declarations into global_decls with correct name and literal value
- [ ] #4 zig build test passes
<!-- AC:END -->
