# TASK-77: Compiler parser + codegen: variables

- Status: Done
- Priority: high
- Labels: compiler, parser, codegen
- Dependencies: TASK-76
- Created: 2026-03-08 · Updated: 2026-03-31

## Description

Add full variable support: declarations, assignments, references, constants, and read counts.

**Parser additions**:
- `VAR name = expr` global declarations (already partially in TASK-74 for literals; extend to expressions)
- `CONST name = expr` — fold at compile time, substitute everywhere referenced
- Logic lines `~ temp name = expr` — temporary variable declaration
- Logic lines `~ name = expr` — variable assignment (detect new-decl vs re-assign by prior declaration)
- Variable reference in expression context: bare identifier `name` → `{"VAR?":"name"}`
- Read count: `{-> knot}` in expression → `{"CNT?":"knot"}`

**Codegen**:
- `VAR name = expr` → emit in `"global decl"` container: `"ev"` expr `{"VAR=":"name"}` `"/ev"`
- `CONST` → no runtime object; substitute value at all use sites
- `~ temp x = expr` → `"ev"` expr `"/ev"` `{"temp=":"x"}`
- `~ x = expr` (new decl) → `"ev"` expr `"/ev"` `{"temp=":"x"}` (or `{"VAR=":"x"}` for globals)
- `~ x = expr` (re-assign) → `"ev"` expr `"/ev"` `{"temp=":"x","re":true}` (or `{"VAR=":"x","re":true}`)
- Variable reference: `{"VAR?":"name"}` (inside eval block) or push to output via ev/out//ev

## Acceptance Criteria
- [ ] compileAndRun passes for all test/fixture/original/runtime/variables/ fixtures
- [ ] CONST values are folded at compile time (no VAR? in emitted JSON for constants)
- [ ] zig build test passes

## Final Summary

Global VAR declarations (global decl container), temp vars, assignments, CONST folding, variable references. All variables/ fixtures pass. Implemented together with TASK-76.
