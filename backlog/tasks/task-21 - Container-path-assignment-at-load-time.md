---
id: TASK-21
title: Container path assignment at load time
status: Done
assignee: []
created_date: '2026-02-23 19:42'
updated_date: '2026-03-01 22:15'
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
- [x] #1 Root container has path ""
- [x] #2 Named child has path equal to its name (if parent is root)
- [x] #3 Index child has path parent.path + "." + index
- [x] #4 Parent pointer set correctly on all containers
- [x] #5 global decl container has correct path
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implementation complete in src/runtime/json_loader.zig — path and parent are assigned during parseContainer. Root gets path="", named children get name (or parent.path+"."+name), index children get parent.path+"."+itoa(index). No explicit tests for these path string values are written yet. All 5 ACs need explicit test coverage before marking Done.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Bug fixed: named inline containers (with #n) were getting index-based paths (e.g., "0.2") instead of name-based paths ("0.g-0"). Fixed in parseContainer: when a content-array container has a name, its path is updated to parent.path+"."+name before adding to named_content. Added 3 fixture tests covering all 5 ACs: hello_world (root path="", inner path="0", g-0 path="0.g-0"), basic_tunnel (f path="f", parent=root), const (global decl path="global decl", parent=root).
<!-- SECTION:FINAL_SUMMARY:END -->
