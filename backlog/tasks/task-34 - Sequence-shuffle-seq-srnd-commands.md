---
id: TASK-34
title: Sequence shuffle (seq / srnd commands)
status: To Do
assignee: []
created_date: '2026-02-23 19:44'
labels:
  - layer-8
  - sequences
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement sequence and shuffle logic in `src/runtime/story.zig`.

- `.control_command(.seed_random)` (`srnd`): pop `.int` from eval stack, set `state.story_seed`
- `.control_command(.sequence_shuffle_index)` (`seq`): pop item-count `n` from eval stack; use `visit_counts[sequence_container.path]` as the step counter; compute next index based on sequence type:
  - Stopping: `@min(step, n - 1)` — clamp at last item
  - Cycle: `step % n`
  - Once: `@min(step, n)` — when step >= n, evaluates to empty content
  - Shuffle: deterministic permutation using `story_seed` XOR-mixed with a hash of the container path; each step uses the next permutation index
- Push the selected index (0-based) as `.int` to eval stack

The sequence type is encoded in the container structure (via `$r`/`$r1`/`$r2` named content and flags).

Tests:
- `sequences/all_sequence_types.ink.json` → all 4 sequence types produce correct output across multiple turns
- `sequences/shuffle_stack_muddying.ink.json` → multiple concurrent shuffles don't interfere
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 all_sequence_types.ink.json produces correct multi-turn output for all 4 types
- [ ] #2 shuffle_stack_muddying.ink.json produces correct output
- [ ] #3 srnd sets story_seed correctly
- [ ] #4 Stopping sequence clamps at last item
- [ ] #5 Cycle sequence wraps correctly
<!-- AC:END -->
