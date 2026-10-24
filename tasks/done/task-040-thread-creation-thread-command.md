# TASK-40: Thread creation (thread command)

- Status: Done
- Priority: high
- Labels: layer-11, threads
- Dependencies: —
- Created: 2026-02-23 · Updated: 2026-03-02

## Description

Implement thread forking in `src/runtime/callstack.zig` and `src/runtime/story.zig`.

- `.control_command(.begin_thread)` (`thread`): deep-clone the current `Thread` state; assign a new `thread_index`; add the clone to `callstack.threads`; the clone starts executing from the next content item after the `thread` command
- Both threads run during `cont()` in sequence until each hits a choice or `done`
- `.control_command(.done)` in a non-primary thread: mark that thread as finished; if other threads remain active, continue with them
- Choices from all threads are merged (sorted by original encounter order) into `state.current_choices`

Tests:
- `threads/multi_thread.ink.json` → choices from both threads appear merged in `currentChoices()`
- `threads/thread_done.ink.json` → thread ending with `done` before the story ends works correctly

## Acceptance Criteria
- [x] multi_thread.ink.json: choices from all threads merged
- [x] thread_done.ink.json: thread done before story end works
- [x] Thread clone executes from correct position
- [x] done in thread removes it from active list
