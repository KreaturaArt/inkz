# TASK-85.9: Compiler: fix remaining string and tag fixture mismatches

- Status: Done
- Priority: medium
- Labels: compiler, integration
- Dependencies: —
- Parent: TASK-85
- Created: 2026-04-07 · Updated: 2026-04-07

## Description

Fix the remaining compiler integration mismatches in the string and tag fixture cluster. Representative fixtures include string_type_coercion, strings_in_choices, tags_dynamic_content, tags_in_choice, and tags_in_seq.

## Acceptance Criteria
- [ ] Remaining string and tag fixtures in this cluster pass compileAndRun
- [ ] No regressions in existing string and tag fixture coverage

## Final Summary

Created and closed the remaining string/tag integration task after re-running the full compiler e2e cluster for strings and tags. The representative and adjacent fixtures are already passing without compiler changes, including string_type_coercion, strings_in_choices, string_constants, string_contains, tags_dynamic_content, tags_in_choice, tags_in_seq, tags.ink, standalone tag lines, basic_string_literals, and newlines_with_string_eval.
