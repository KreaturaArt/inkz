---
id: TASK-29
title: ChoicePoint — build Choice from eval stack
status: To Do
assignee: []
created_date: '2026-02-23 19:44'
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
- [ ] #1 choice_with_brackets_only.ink.json: currentChoices() has 1 choice with text "Option"
- [ ] #2 Once-only flag skips choice when visit_count > 0
- [ ] #3 Condition flag skips choice when eval stack bool is false
- [ ] #4 Choice text assembled correctly from start+only content parts
<!-- AC:END -->
