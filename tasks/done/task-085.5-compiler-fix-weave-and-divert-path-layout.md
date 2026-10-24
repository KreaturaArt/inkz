# TASK-85.5: Compiler: fix weave and divert path layout

- Status: Done
- Priority: high
- Labels: compiler, integration
- Dependencies: —
- Parent: TASK-85
- Created: 2026-04-07 · Updated: 2026-04-07

## Description

Fix nested weave container layout and divert path generation. Current failing fixtures include conditional_choice_in_weave, conditional_choice_in_weave_2, unbalanced_weave_indentation, divert_to_weave_points, and extra/list_comparison.

## Acceptance Criteria
- [ ] All listed weave/divert fixtures pass compileAndRun
- [ ] Nested weave choices and gathers resolve to valid runtime paths
- [ ] No DivertTargetNotFound errors in this fixture cluster

## Final Summary

Fixed weave and divert path layout in parser/codegen. Conditional branch bodies now converge via correct relative nop paths, gather sections fall through to the next gather when needed, brace-scoped choice parsing stops correctly at right braces, and variable function calls serialize with var=true. Verified with turns_since_nested, divert_to_weave_points, conditional_choice_in_weave, conditional_choice_in_weave_2, unbalanced_weave_indentation, and list_comparison fixtures.
