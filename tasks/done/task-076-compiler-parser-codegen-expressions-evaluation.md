# TASK-76: Compiler parser + codegen: expressions & evaluation

- Status: Done
- Priority: high
- Labels: compiler, parser, codegen
- Dependencies: TASK-75
- Created: 2026-03-08 · Updated: 2026-03-31

## Description

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

## Acceptance Criteria
- [ ] compileAndRun passes for all test/fixture/original/runtime/evaluation/ fixtures
- [ ] compileAndRun passes for all test/fixture/original/runtime/booleans/ fixtures
- [ ] zig build test passes

## Final Summary

Precedence-climbing expression parser. Binary/unary operators, function calls (no-arg and with-arg), variable references, read counts, divert targets. All evaluation/ and booleans/ fixtures pass. Implemented together with TASK-77.
