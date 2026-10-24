# TASK-85.1: Compiler: fix string-eval codegen failures

- Status: Done
- Priority: high
- Labels: compiler, integration
- Dependencies: —
- Parent: TASK-85
- Created: 2026-04-07 · Updated: 2026-04-07

## Description

Fix compiler handling for string evaluation and nested string interpolation. Current failing fixtures are runtime/misc/quote_character_significance.ink and runtime/newlines/newlines_with_string_eval.ink.

## Acceptance Criteria
- [ ] quote_character_significance.ink passes compileAndRun
- [ ] newlines_with_string_eval.ink passes compileAndRun
- [ ] No regression in existing string fixture coverage

## Implementation Notes

Implemented interpolated string parsing/codegen for quoted strings and brace expressions.

Fixed runtime string evaluation so numeric and other visible non-string values are preserved inside string interpolation.

Verified suite moved from 460 pass / 25 fail to 461 pass / 24 fail; string-eval failures cleared.

## Final Summary

Added interpolated string parsing/codegen and fixed runtime string-eval assembly so embedded expressions like `"{3}"` return visible text correctly. This cleared the remaining string-eval failures and moved the suite to 461/485 passing.
