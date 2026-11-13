# P7.0 parser spike: go/no-go

**Decision: go.** An explicit-stack parser handles ink's hardest nesting with the planned
node layout, without recursion. The spike is `src/compiler_next/spike.zig` (throwaway; it is
deleted once P7.3's parser core replaces it). Its five tests parse hand-picked hard inputs:

1. A multi-line conditional `{ x > 1: … - else: … }` whose branch holds a weave with a choice
   whose `[...]` holds an inline `{y}`, a nested `**` choice, and a gather.
2. Sequences and conditionals nested inside each other: `{&one|{x: two {~a|b}|three}|four}`.
3. An expression with precedence, parentheses and `not`: `{a + b * (c - d) > 3 and not e: …}`.
4. A conditional choice with brackets holding nested braces: `* {seen > 0} [Ask {about: {x}|…}] …`.
5. A switch block whose case branches hold content on the same line and choices below it.

## What worked

- **One heterogeneous frame stack.** Frames are a small struct tagged by construct (story,
  weave level, choice, block, block branch, line, inline brace, brace branch). The main loop
  looks at the top frame and runs one step of it; a step either consumes input, pushes a
  frame, or finishes the frame. Nesting of any mix of constructs is just more frames.
- **zirp's scratch stack and `wrap`.** A finished node is pushed on the scratch stack as a
  value; when its parent finishes, `wrap` copies its children's values into one contiguous run
  of the node array. Children are therefore contiguous, nodes are append-only, and
  backtracking only truncates counts.
- **Shunting-yard expressions.** Operands go on the same scratch stack; operators wait on a
  local stack and `wrap` their operands as they leave it. Parentheses are markers on the
  operator stack; prefix `not` reduces after its operand.
- **Weave levels.** A choice or gather marker's depth (`*`, `**`, `-`, `--`) is compared with
  the open weave level: deeper opens a nested weave inside the choice, shallower closes levels.
- **The gas counter** (a bound proportional to the input length) held as the progress
  invariant: every step consumes input or closes a frame.

## Adjustments for P7.3

- **A phase per frame.** The spike packs a choice's phase into spare bits; the real frame gets
  an explicit `phase` enum and a small data union per construct.
- **Content stops as a `TagSet`** (T7) per frame instead of an enum, since the stopping
  characters depend on every enclosing construct (`]` in choice brackets, `|` and `}` in
  braces, `:` in some headers).
- **Lookahead decisions.** ink's grammar decides several constructs by looking ahead: a `{` at
  a line start that is a block, an inline brace that is a conditional (a `:` before its `}` at
  depth 0), and a `- expr:` block branch versus a gather. The spike scans characters; the real
  parser uses token lookahead from the mode-aware tokenizer (P7.1), or ink-style save and
  restore, which the layout supports (restoring is truncating counts).
- **Recovery instead of errors.** The spike returns errors; the real parser records
  diagnostics and `.missing` nodes and keeps going (T5), with `parse_depth_max` as the frame
  limit.
- **Node size.** The spike's nodes carry a child count (9 B). The planned 5 B node (P7.2) gets
  fixed arities from the tag and stores list lengths in `extra`.
- **ink's whitespace rules** (for example the space after `:` in `{x: yes|no}`) are not the
  spike's subject; P7.5 follows InkParser's exact rules, checked against ink's compiler.
- **Function calls and unary minus** need a call frame on the operator stack (argument
  counts) and ink's precedence table (InkParser_Expressions.cs).

**Outcome (2026-11-12).** The spike's code was deleted once the grammar landed (P7.4-P7.8).
The grammar kept the go decision's design: an explicit frame stack with checkpoints, the
scratch stack and `wrap`. It differs in being a faithful port of InkParser rather than a
shunting-yard parser: each InkParser method that can recurse is a rule frame, expressions
use precedence climbing through frames, and ink's whitespace rules come from InkParser.
