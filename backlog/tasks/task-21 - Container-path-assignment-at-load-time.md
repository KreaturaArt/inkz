---
id: TASK-21
title: Container path assignment at load time
status: To Do
assignee: []
created_date: '2026-02-23 19:42'
labels:
  - layer-2
  - loader
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Extend `src/runtime/json_loader.zig`: after loading the container tree, walk every container and assign `container.path` (dot-separated string) and `container.parent` pointer.

Assignment rules:
- Root container: `path = ""`
- Named child in `named_content`: `path = parent.path + "." + name` (if parent is root, just `name`)
- Index child in `content` array (if it's a container): `path = parent.path + "." + itoa(index)`
- Special: `"global decl"` container gets `path = "global decl"` and is otherwise treated normally

Requires `Container` to have `path: []const u8` and `parent: ?*Container` fields (add to TASK-5).

**Rationale:** TASK-18 (visit counts) and TASK-30 (path API) both key their maps on these stable path strings.

Tests:
- Load `misc/hello_world.ink.json`: root has `path == ""`; the inner container at index 0 has `path == "0"`; the named container `"g-0"` inside has `path == "0.g-0"`
- Load `diverts/basic_tunnel.ink.json`: named container `"f"` has `path == "f"`; its `parent` points to root
- Load `variables/const.ink.json`: `"global decl"` container has `path == "global decl"`; its parent is root
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Root container has path ""
- [ ] #2 Named child has path equal to its name (if parent is root)
- [ ] #3 Index child has path parent.path + "." + index
- [ ] #4 Parent pointer set correctly on all containers
- [ ] #5 global decl container has correct path
<!-- AC:END -->
