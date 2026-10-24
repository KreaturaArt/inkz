# TASK-51: Tests: runtime/choices — remaining 12 fixtures

- Status: Done
- Priority: medium
- Labels: tests, choices
- Dependencies: —
- Created: 2026-03-02 · Updated: 2026-03-05

## Description

Add story-level integration tests for the twelve choice fixtures that currently have no test.

Fixtures to cover:
- `runtime/choices/choice_count.ink.json`
- `runtime/choices/choice_diverts_to_done.ink.json`
- `runtime/choices/choice_thread_forking.ink.json`
- `runtime/choices/default_simple_gather.ink.json`
- `runtime/choices/fallback_choice_on_thread.ink.json`
- `runtime/choices/gather_choice_same_line.ink.json`
- `runtime/choices/has_read_on_choice.ink.json`
- `runtime/choices/logic_in_choices.ink.json`
- `runtime/choices/non_text_in_choice_inner_content.ink.json`
- `runtime/choices/should_not_gather_due_to_choice.ink.json`
- `runtime/choices/state_rollback_over_default_choice.ink.json`
- `runtime/choices/various_default_choices.ink.json`

Already covered: choice_with_brackets_only, once_only_choices_can_link_back_to_self, sticky_choices_stay_sticky, once_only_choices_with_own_content, default_choices, conditional_choices.

For choice-driven fixtures, use `chooseChoiceIndex` to drive a known choice path and assert the resulting output.

## Acceptance Criteria
- [ ] One test per fixture listed above
- [ ] Choice-driven fixtures driven via chooseChoiceIndex with a known path
- [ ] All tests pass with `zig build test`
