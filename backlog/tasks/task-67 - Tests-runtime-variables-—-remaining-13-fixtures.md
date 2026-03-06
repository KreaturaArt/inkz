---
id: TASK-67
title: 'Tests: runtime/variables — remaining 13 fixtures'
status: Done
assignee: []
created_date: '2026-03-02 20:24'
updated_date: '2026-03-06 13:58'
labels:
  - tests
  - variables
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add story-level integration tests for thirteen variable fixtures that currently have no test.

Fixtures to cover:
- `runtime/variables/multiple_constant_references.ink.json`
- `runtime/variables/set_non_existant_variable.ink.json`
- `runtime/variables/temp_global_conflict.ink.json`
- `runtime/variables/temp_not_found.ink.json`
- `runtime/variables/temp_usage_in_options.ink.json`
- `runtime/variables/temporaries_at_global_scope.ink.json`
- `runtime/variables/variable_declaration_in_conditional.ink.json`
- `runtime/variables/variable_get_set_api.ink.json`
- `runtime/variables/variable_pointer_ref_from_knot.ink.json`
- `runtime/variables/variable_swap_recurse.ink.json`
- `runtime/variables/variable_tunnel.ink.json`
- `runtime/variables/warn_variable_not_found_1.ink.json`
- `runtime/variables/warn_variable_not_found_2.ink.json`

Already covered: const, variable_divert_target.

Note: `set_non_existant_variable`, `temp_not_found`, `warn_variable_not_found_*` may trigger runtime errors — assert the error type rather than output.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 One test per fixture
- [ ] #2 Error-producing fixtures assert the expected error tag
- [ ] #3 Output-producing fixtures assert exact output
- [ ] #4 All 13 tests pass with `zig build test`
<!-- AC:END -->
