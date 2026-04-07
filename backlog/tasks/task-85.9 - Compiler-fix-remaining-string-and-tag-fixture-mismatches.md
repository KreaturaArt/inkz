---
id: TASK-85.9
title: 'Compiler: fix remaining string and tag fixture mismatches'
status: Done
assignee: []
created_date: '2026-04-07 19:32'
updated_date: '2026-04-07 19:32'
labels:
  - compiler
  - integration
dependencies: []
parent_task_id: TASK-85
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Fix the remaining compiler integration mismatches in the string and tag fixture cluster. Representative fixtures include string_type_coercion, strings_in_choices, tags_dynamic_content, tags_in_choice, and tags_in_seq.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Remaining string and tag fixtures in this cluster pass compileAndRun
- [ ] #2 No regressions in existing string and tag fixture coverage
<!-- AC:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Created and closed the remaining string/tag integration task after re-running the full compiler e2e cluster for strings and tags. The representative and adjacent fixtures are already passing without compiler changes, including string_type_coercion, strings_in_choices, string_constants, string_contains, tags_dynamic_content, tags_in_choice, tags_in_seq, tags.ink, standalone tag lines, basic_string_literals, and newlines_with_string_eval.
<!-- SECTION:FINAL_SUMMARY:END -->
