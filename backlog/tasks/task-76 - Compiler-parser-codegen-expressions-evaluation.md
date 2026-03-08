---
id: TASK-76
title: 'Compiler parser + codegen: expressions & evaluation'
status: To Do
assignee: []
created_date: '2026-03-08 15:46'
labels:
  - compiler
  - parser
  - codegen
dependencies:
  - TASK-75
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add expression parsing and postfix codegen for inline `{expr}` blocks.

**Parser**: Precedence-climbing expression parser.
- Literals: integers, floats, booleans (`true`/`false`)
- Identifiers: variable references `{x}`, read-count `{-> knot}`
- Binary operators (by precedence): `||`/`or`, `&&`/`and`, `==` `!=` `>` `<` `>=` `<=`, `+` `-`, `*` `/` `%`/`mod`
- Unary: `-` (negate), `!`/`not`
- Parentheses grouping
- Built-in calls: `FLOOR()`, `CEILING()`, `INT()`, `FLOAT()`, `MIN()`, `MAX()`

**Codegen**: Emit postfix evaluation sequence for `{expr}`:
```
"ev"  [operands and operators in postfix order]  "out"  "/ev"  "\n"
```
- Each `{expr}` on its own line wraps in ev/out//ev + newline
- Inline `{expr}` within text line: ev/out//ev without surrounding newline (glued into text)
- `mod` keyword → `"%"` operator string
- `and`/`or`/`not` → `"&&"`/`"||"`/`"!"` operator strings
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 compileAndRun passes for all test/fixture/original/runtime/evaluation/ fixtures
- [ ] #2 compileAndRun passes for all test/fixture/original/runtime/booleans/ fixtures
- [ ] #3 zig build test passes
<!-- AC:END -->
