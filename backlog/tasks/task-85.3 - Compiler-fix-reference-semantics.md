---
id: TASK-85.3
title: 'Compiler: fix reference semantics'
status: Done
assignee: []
created_date: '2026-04-07 09:02'
updated_date: '2026-04-07 09:38'
labels:
  - compiler
  - integration
dependencies: []
parent_task_id: TASK-85
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Fix compiler handling for pass-by-reference arguments and variable pointer propagation in function calls. Representative failures were runtime/evaluation/factorial_by_reference.ink, runtime/logic/nested_pass_by_reference.ink, and runtime/variables/variable_pointer_ref_from_knot.ink.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 factorial_by_reference.ink passes compileAndRun
- [ ] #2 nested_pass_by_reference.ink passes compileAndRun
- [ ] #3 variable_pointer_ref_from_knot.ink passes compileAndRun
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Added function-signature-aware call lowering so ref parameters compile to variable-pointer objects instead of plain value reads.

Serialized Parsed.Expression.var_pointer through codegen/serializer and verified reference fixtures now pass.

Suite moved from 462 pass / 23 fail to 465 pass / 20 fail after the reference fix.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Fixed pass-by-reference compilation by lowering ref call arguments to variable-pointer objects using function signature metadata. This cleared the main reference-semantics fixtures and moved the suite to 465/485 passing.
<!-- SECTION:FINAL_SUMMARY:END -->
