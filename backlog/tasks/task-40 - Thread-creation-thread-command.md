---
id: TASK-40
title: Thread creation (thread command)
status: To Do
assignee: []
created_date: '2026-02-23 19:45'
labels:
  - layer-11
  - threads
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement thread forking in `src/runtime/callstack.zig` and `src/runtime/story.zig`.

- `.control_command(.begin_thread)` (`thread`): deep-clone the current `Thread` state; assign a new `thread_index`; add the clone to `callstack.threads`; the clone starts executing from the next content item after the `thread` command
- Both threads run during `cont()` in sequence until each hits a choice or `done`
- `.control_command(.done)` in a non-primary thread: mark that thread as finished; if other threads remain active, continue with them
- Choices from all threads are merged (sorted by original encounter order) into `state.current_choices`

Tests:
- `threads/multi_thread.ink.json` → choices from both threads appear merged in `currentChoices()`
- `threads/thread_done.ink.json` → thread ending with `done` before the story ends works correctly
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 multi_thread.ink.json: choices from all threads merged
- [ ] #2 thread_done.ink.json: thread done before story end works
- [ ] #3 Thread clone executes from correct position
- [ ] #4 done in thread removes it from active list
<!-- AC:END -->
