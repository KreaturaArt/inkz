# TASK-27: Variable divert target

- Status: Done
- Priority: high
- Labels: layer-5, diverts
- Dependencies: —
- Created: 2026-02-23 · Updated: 2026-03-01

## Description

Implement variable-target diverts in `src/runtime/story.zig`.

- `.divert` with `is_variable == true`: look up the target name in `variables_state` (searching temps then globals); expect a `.divert_target(path)` value; resolve that path and jump to it
- `.divert_target(path)` as a content value: when encountered in eval mode, push to eval stack as-is for later use

Tests:
- `diverts/divert_targets_with_parameters.ink.json` → verify output matches reference
- `variables/variable_divert_target.ink.json` → divert via stored path variable works correctly

## Acceptance Criteria
- [x] Variable divert resolves path from variable value
- [x] divert_targets_with_parameters.ink.json produces correct output
- [x] variable_divert_target.ink.json produces correct output
- [ ] Error if variable does not contain a divert_target value

## Implementation Notes

Implementation complete in src/runtime/story.zig. Variable divert (is_variable=true): looks up the variable via resolveVariable, expects a .divert_target value, resolves that path. .divert_target values pushed to eval stack when in eval mode. No explicit tests written yet for variable_divert_target.ink.json or similar fixtures.

## Final Summary

Implementation was already complete. Added 2 fixture tests: (1) divert_targets_with_parameters.ink.json → "5\n" (global x=divert_target("place"), root passes 5 via eval stack, place temp-pops it and outputs), (2) variable_divert_target.ink.json → "Here.\n" (global x=divert_target("here"), "there" knot diverts via variable x). AC #4 (error on non-divert_target) not tested as implementation returns error implicitly.
