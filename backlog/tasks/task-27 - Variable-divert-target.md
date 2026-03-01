---
id: TASK-27
title: Variable divert target
status: In Progress
assignee: []
created_date: '2026-02-23 19:43'
updated_date: '2026-03-01 17:33'
labels:
  - layer-5
  - diverts
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement variable-target diverts in `src/runtime/story.zig`.

- `.divert` with `is_variable == true`: look up the target name in `variables_state` (searching temps then globals); expect a `.divert_target(path)` value; resolve that path and jump to it
- `.divert_target(path)` as a content value: when encountered in eval mode, push to eval stack as-is for later use

Tests:
- `diverts/divert_targets_with_parameters.ink.json` → verify output matches reference
- `variables/variable_divert_target.ink.json` → divert via stored path variable works correctly
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Variable divert resolves path from variable value
- [ ] #2 divert_targets_with_parameters.ink.json produces correct output
- [ ] #3 variable_divert_target.ink.json produces correct output
- [ ] #4 Error if variable does not contain a divert_target value
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implementation complete in src/runtime/story.zig. Variable divert (is_variable=true): looks up the variable via resolveVariable, expects a .divert_target value, resolves that path. .divert_target values pushed to eval stack when in eval mode. No explicit tests written yet for variable_divert_target.ink.json or similar fixtures.
<!-- SECTION:NOTES:END -->
