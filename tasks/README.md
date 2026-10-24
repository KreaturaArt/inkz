# Tasks

Tasks are plain markdown files. No external tool is needed to read or edit them.

## Layout

- `tasks/open/`: work that is not done yet (status `To Do` or `In Progress`).
- `tasks/done/`: finished work. When a task is done, move its file here and add a row to
  `tasks/done/INDEX.md`.

## File name

`task-NNN-short-slug.md`, with the id zero-padded to three digits so files sort in order.
Subtasks use a dotted id: `task-085.3-short-slug.md`. To pick the next id, take the highest
existing id across `open/` and `done/` and add one.

## Format

```markdown
# TASK-NNN: Title

- Status: To Do | In Progress | Done
- Priority: high | medium | low
- Labels: comma, separated
- Dependencies: TASK-12, TASK-13 (say what each one provides)
- Parent: TASK-85 (subtasks only)
- Created: yyyy-mm-dd · Updated: yyyy-mm-dd

## Description

Why the work matters and the context someone new to it needs.

## Acceptance Criteria
- [ ] Specific, testable outcome, validated by a unit test.

## Implementation Notes

Plan and progress notes, written while the work is in progress.

## Final Summary

What changed and how it was verified, written when the task is done.
```

## Rules

- Every task needs success criteria. An implementation task is complete only when one or more
  unit tests validate those criteria.
- Keep the `Status` line in sync with the folder the file is in.
