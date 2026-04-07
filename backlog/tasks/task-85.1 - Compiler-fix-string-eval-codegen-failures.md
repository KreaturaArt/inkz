---
id: TASK-85.1
title: 'Compiler: fix string-eval codegen failures'
status: Done
assignee: []
created_date: '2026-04-07 09:02'
updated_date: '2026-04-07 09:09'
labels:
  - compiler
  - integration
dependencies: []
parent_task_id: TASK-85
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Fix compiler handling for string evaluation and nested string interpolation. Current failing fixtures are runtime/misc/quote_character_significance.ink and runtime/newlines/newlines_with_string_eval.ink.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 quote_character_significance.ink passes compileAndRun
- [ ] #2 newlines_with_string_eval.ink passes compileAndRun
- [ ] #3 No regression in existing string fixture coverage
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented interpolated string parsing/codegen for quoted strings and brace expressions.

Fixed runtime string evaluation so numeric and other visible non-string values are preserved inside string interpolation.

Verified suite moved from 460 pass / 25 fail to 461 pass / 24 fail; string-eval failures cleared.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Added interpolated string parsing/codegen and fixed runtime string-eval assembly so embedded expressions like `"{3}"` return visible text correctly. This cleared the remaining string-eval failures and moved the suite to 461/485 passing.
<!-- SECTION:FINAL_SUMMARY:END -->
