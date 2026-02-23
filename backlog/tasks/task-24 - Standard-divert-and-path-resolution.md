---
id: TASK-24
title: Standard divert and path resolution
status: To Do
assignee: []
created_date: '2026-02-23 19:43'
labels:
  - layer-5
  - diverts
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement path resolution and standard divert execution in `src/runtime/pointer.zig` and `src/runtime/story.zig`.

`resolvePath(root: *Container, current: *Container, path: Path) ?*Container`:
- Absolute path (is_relative=false): start from root
- Relative path (is_relative=true): start from current; `.parent` component goes up via `container.parent`
- `.index(n)` component: descend into `container.content[n]` if it is a `.container` variant
- `.name(s)` component: descend into `container.named_content.get(s)`

In `step()`, when `.divert` with `is_conditional==false`, `is_variable==false`, `push_pop_type==null`: resolve path, set `currentPointer` to resolved container at index 0.

Tests:
- Unit: resolve `"f"` from root of loaded `diverts/basic_tunnel.ink.json` → the `"f"` container
- Unit: resolve `".^.g-0"` relative to inner container → parent's named `"g-0"` container
- Unit: resolve non-existent path → `null`
- `diverts/same_line_divert_is_inline.ink.json` → correct output after divert jump
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 resolvePath with absolute path finds named container
- [ ] #2 resolvePath with relative path and ^ traverses parent correctly
- [ ] #3 resolvePath with non-existent path returns null
- [ ] #4 same_line_divert_is_inline.ink.json produces correct output
<!-- AC:END -->
