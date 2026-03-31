---
id: TASK-77
title: 'Compiler parser + codegen: variables'
status: Done
assignee: []
created_date: '2026-03-08 15:46'
updated_date: '2026-03-31 18:12'
labels:
  - compiler
  - parser
  - codegen
dependencies:
  - TASK-76
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
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
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 compileAndRun passes for all test/fixture/original/runtime/variables/ fixtures
- [ ] #2 CONST values are folded at compile time (no VAR? in emitted JSON for constants)
- [ ] #3 zig build test passes
<!-- AC:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Global VAR declarations (global decl container), temp vars, assignments, CONST folding, variable references. All variables/ fixtures pass. Implemented together with TASK-76.
<!-- SECTION:FINAL_SUMMARY:END -->
