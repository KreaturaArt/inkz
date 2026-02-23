---
id: TASK-30
title: Invisible default choice + sticky + once-only
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
- [ ] #1 sticky_choices_stay_sticky.ink.json: choice reappears after selection
- [ ] #2 once_only_choices_with_own_content.ink.json: choice absent after first selection
- [ ] #3 default_choices.ink.json: auto-follows when no other choices
<!-- AC:END -->
