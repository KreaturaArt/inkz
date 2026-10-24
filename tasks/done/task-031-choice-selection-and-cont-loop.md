# TASK-31: Choice selection and cont() loop

- Status: Done
- Priority: high
- Labels: layer-6, choices
- Dependencies: —
- Created: 2026-02-23 · Updated: 2026-03-02

## Description

Implement `chooseChoiceIndex`, `canContinue`, and the full `cont()` loop in `src/runtime/story.zig`.

- `chooseChoiceIndex(i: usize) !void`: validate `i < current_choices.len`; resolve `choice.target_path`; set `currentPointer` to that container at index 0; clear `current_choices`; increment `current_turn_index`
- `canContinue() bool`: pointer is non-null and `!did_safe_exit`
- Full `cont()` loop: call `step()` until `.stopped`; then call `tryFollowDefaultInvisibleChoice()` and if it jumped, loop again; collect output_stream text; clear stream; return owned string

Tests:
- `choices/choice_with_brackets_only.ink.json`:
  1. `cont()` → `""` (no text before choice)
  2. `currentChoices()[0].text == "Option"`
  3. `chooseChoiceIndex(0)` → `cont()` → `"\nText\n"`
- `choices/conditional_choices.ink.json` → only choices with true conditions appear
- `canContinue()` is false after `cont()` exhausts the story

## Acceptance Criteria
- [x] choice_with_brackets_only.ink.json: full play-through gives correct output
- [x] conditional_choices.ink.json: only enabled choices visible
- [x] canContinue() false after story ends
- [x] chooseChoiceIndex out of range returns error

## Final Summary

All implementation already complete from TASK-29/30. Added tests: conditional_choices.ink.json → 4 choices visible (c-0 and c-2 filtered by false conditions), canContinue() false after story ends, chooseChoiceIndex out-of-range returns error.InvalidChoiceIndex.
