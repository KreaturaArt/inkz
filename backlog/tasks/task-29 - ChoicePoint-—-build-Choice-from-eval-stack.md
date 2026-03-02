---
id: TASK-29
title: ChoicePoint — build Choice from eval stack
status: Done
assignee: []
created_date: '2026-02-23 19:44'
updated_date: '2026-03-01 23:33'
labels:
  - layer-6
  - choices
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement choice building in `src/runtime/choices.zig` and `src/runtime/story.zig`.

**Depends on TASK-28 (string eval mode) — choice text uses str/str blocks.**

The choice_point flags byte:
- `0x01`: has condition — pop bool from eval stack; skip if false
- `0x02`: has start content — pop string from eval stack → prepend to choice text
- `0x04`: has choice-only content — pop string from eval stack → append to choice text
- `0x08`: is invisible default — don't surface to player (handled in next task)
- `0x10`: is once-only — skip if `visit_count[target_path] > 0`

Build `Choice.text` from (start_content + choice_only_content). Resolve `choice.target_path` using `resolvePath`. Append to `state.current_choices`.

`currentChoices() []Choice` method on Story.

Tests:
- `choices/choice_with_brackets_only.ink.json`: after first `cont()`, `currentChoices()` has 1 choice; `choices[0].text == "Option"`
- `choices/once_only_choices_can_link_back_to_self.ink.json` → once-only choice appears first turn, absent second turn
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 choice_with_brackets_only.ink.json: currentChoices() has 1 choice with text "Option"
- [x] #2 Once-only flag skips choice when visit_count > 0
- [x] #3 Condition flag skips choice when eval stack bool is false
- [x] #4 Choice text assembled correctly from start+only content parts
<!-- AC:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Implemented processChoicePoint in story.zig. Key fixes: (1) condition pop always happens, then choice_only and start pops happen unconditionally before deciding whether to add the choice — early return after condition left stale values on eval stack; (2) target_path in Choice stores the resolved absolute container.path (not the relative path_str) so chooseChoiceIndex works when the pointer is null post-cont(); (3) IsInvisibleDefault (0x08) skips adding to current_choices; (4) chooseChoiceIndex calls recordVisitIfNeeded on the target so once-only choices are properly tracked. Tests: choice_with_brackets_only → 1 choice "Option" → "\nText\n"; once_only_choices_can_link_back_to_self → turn 1 shows "First choice" only (c-1 condition CNT?=0 falsy), turn 2 after selecting "First choice" shows "Second choice" only (c-0 once-only, visited).
<!-- SECTION:FINAL_SUMMARY:END -->
