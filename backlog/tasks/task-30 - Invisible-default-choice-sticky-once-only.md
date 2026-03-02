---
id: TASK-30
title: Invisible default choice + sticky + once-only
status: Done
assignee: []
created_date: '2026-02-23 19:44'
updated_date: '2026-03-02 04:32'
labels:
  - layer-6
  - choices
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement default invisible choice auto-follow and sticky/once-only filtering in `src/runtime/choices.zig` and `src/runtime/story.zig`.

- Once-only (`0x10` flag set): skip choice if `visit_counts[target_path] > 0` (already handled in choice building, test here)
- Sticky (flag `0x10` absent): always shown regardless of visit count
- Invisible default (`0x08` flag): don't add to `current_choices`; store separately on state
- `tryFollowDefaultInvisibleChoice()`: if `current_choices` is empty after step loop and an invisible default was recorded, auto-follow it (jump to its target)

Tests:
- `choices/sticky_choices_stay_sticky.ink.json` → sticky choice reappears after selection
- `choices/once_only_choices_with_own_content.ink.json` → once-only choice disappears after first selection
- `choices/default_choices.ink.json` → invisible default auto-follows when no other choices remain
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 sticky_choices_stay_sticky.ink.json: choice reappears after selection
- [x] #2 once_only_choices_with_own_content.ink.json: choice absent after first selection
- [x] #3 default_choices.ink.json: auto-follows when no other choices
<!-- AC:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Added `default_choice_target: ?[]const u8 = null` field to Story. Moved the IsInvisibleDefault (0x08) check AFTER path resolution and IsOnce check in processChoicePoint — when the invisible default passes all checks, it stores the resolved absolute container path in `default_choice_target` instead of adding to current_choices. Refactored cont() main loop into `runStepLoop()`, then after runStepLoop: if current_choices is empty and default_choice_target is set, jump to that target (recording a visit), increment turn_index, and run the step loop again. Tests: sticky_choices_stay_sticky → 2 choices appear each turn (no IsOnce); once_only_choices_with_own_content → 3 choices turn 1, 2 choices turn 2 (chosen item gone); default_choices → 2 choices turn 1, 1 choice turn 2, turn 3 auto-follows invisible default and outputs "This is default."
<!-- SECTION:FINAL_SUMMARY:END -->
