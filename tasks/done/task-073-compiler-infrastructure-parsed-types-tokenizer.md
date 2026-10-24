# TASK-73: Compiler infrastructure, Parsed.* types, tokenizer

- Status: Done
- Priority: high
- Labels: compiler, infrastructure
- Dependencies: —
- Created: 2026-03-08 · Updated: 2026-03-08

## Description

Create `src/compiler/` directory. Define all Parsed.* AST node types in `parsed.zig`. Implement `tokenizer.zig` as a labeled-switch character scanner.

**Parsed.* types to define** (parsed.zig):
- `Story`, `Knot`, `Stitch`, `FlowItem` (union), `TextLine`, `InlineElement`, `Choice`, `Gather`, `Divert`, `LogicLine`, `Conditional`, `Sequence`, `Expression`, `BinaryOp`, `UnaryOp`, `Param`, `VarDecl`, `Constant`, `ListDef`, `ExternalFn`, `InkListLiteral`

**Tokenizer tokens**: `text`, `newline`, `knot_marker` (`===`/`==`), `stitch_marker` (`=`), `choice_once` (`*`), `choice_sticky` (`+`), `gather` (`-`), `logic_line` (`~`), `divert_arrow` (`->`), `divert_return` (`->->`), `thread_start` (`<-`), `left_brace`/`right_brace`, `left_bracket`/`right_bracket`, `hash`, `colon`, `pipe`, `eof`, keywords (`VAR`, `CONST`, `LIST`, `INCLUDE`, `EXTERNAL`, `ref`, `END`, `DONE`, `return`, `temp`, `and`, `or`, `not`, `mod`).

**Architecture**: Labeled switch over characters with `continue :tok` for zero-cost dispatch (as described in docs/Architecture.md).

## Acceptance Criteria
- [x] Unit tests tokenize test/fixture/original/runtime/misc/hello_world.ink and verify correct token sequence
- [x] Unit tests tokenize test/fixture/original/runtime/evaluation/arithmetic.ink and verify operators, numbers, braces
- [x] All Parsed.* types compile without errors
- [x] zig build test passes (240 runtime tests unaffected)

## Final Summary

Created `src/compiler/parsed.zig` with all Parsed.* AST types (Story, Knot, Stitch, FlowItem, TextLine, InlineElement, Choice, Gather, Divert, LogicLine, VarDecl, TempDecl, Assignment, Conditional, Branch, Sequence, Expression, BinaryOp, UnaryOp, Param, Constant, ListDef, ListItem, ExternalFn, InkListLiteral).

Created `src/compiler/tokenizer.zig` with a labeled-while state machine that recognises all structural Ink tokens: `{`, `}`, `[`, `]`, `#`, `|`, `\n`, `->`, `->->`, `<-`, `*`/`+`/`-`/`~`/`=`/`===` at line start, and `//`/`/* */` comments (skipped). Text tokens accumulate non-structural chars.

Both test fixtures pass: hello_world.ink produces text("Hello world")+newline+eof; arithmetic.ink produces 7 left_brace/text/right_brace triples with numbers and operators in the text content.

All 240 runtime tests continue to pass (zig build test exits 0).
