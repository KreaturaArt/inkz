# TASK-80: Compiler parser + codegen: functions, tunnels, external functions

- Status: Done
- Priority: high
- Labels: compiler, parser, codegen
- Dependencies: TASK-79
- Created: 2026-03-08 · Updated: 2026-04-05

## Description

Add function knots, function calls, tunnels, return statements, and external function declarations.

**Parser additions**:
- Function knot: `=== func_name(param1, param2) ===` — is_function=true, params list
- Reference params: `ref x` in param list → variable pointer argument
- Tunnel syntax: `-> tunnel_name ->` — divert with push type tunnel
- Tunnel return: `->->` — pop tunnel frame
- Function return: `~ return expr` — evaluate expr then pop function frame
- External function declaration: `EXTERNAL func_name(n)` — records name and arg count
- Function call in expression: `func_name(arg1, arg2)` — push args + f() divert + pop

**Codegen**:
- Function knot: each param → `{"temp=":"name"}` at top of container; implicit return at end: `"ev"` `"void"` `"/ev"` `"~ret"`
- `~ return expr` → emit eval(expr) + `"/ev"` + `"~ret"` (note: expr eval is already in ev mode for logic lines)
- Function call: emit args in eval mode + `{"f()":"path.to.func"}` + `"pop"` (in expression: no pop, result stays on stack)
- Reference param: `{"^var":"name","ci":-1}` as argument value
- Tunnel divert: `{"->t->":"target"}`; tunnel return: `"->->"`
- Tunnel end: `"ev"` `"void"` `"/ev"` `"->->"` (same as function but pop_tunnel)
- External call: `{"x()":"func_name","exArgs":N}`
- EXTERNAL declaration: records in story for validation but emits nothing

Reference: Read `test/fixture/original/runtime/diverts/basic_tunnel.ink` and `test/fixture/original/runtime/diverts/knot_with_param.ink` + compiled JSON before implementing.

## Acceptance Criteria
- [x] compileAndRun passes for all test/fixture/original/runtime/diverts/ fixtures
- [x] compileAndRun passes for all test/fixture/original/runtime/callstack/ fixtures
- [x] compileAndRun passes for all test/fixture/original/runtime/bindings/ fixtures
- [x] zig build test passes

## Final Summary

Implemented in the same session as TASK-79/82/83 (git: "(complete) TASK-79/80/82/83"). Function knots with params, tunnels, tunnel-onwards, external function declarations, function calls, reference params, and x++/x-- increment/decrement all working. 414/414 tests pass.
