# TASK-24: Standard divert and path resolution

- Status: Done
- Priority: high
- Labels: layer-5, diverts
- Dependencies: —
- Created: 2026-02-23 · Updated: 2026-03-01

## Description

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

## Acceptance Criteria
- [x] resolvePath with absolute path finds named container
- [x] resolvePath with relative path and ^ traverses parent correctly
- [x] resolvePath with non-existent path returns null
- [x] same_line_divert_is_inline.ink.json produces correct output

## Implementation Notes

Implementation complete in src/runtime/story.zig. resolvePath(path_str, from_ptr) returns Pointer (not *Container). Key semantics: the first ^ in a relative path steps from instruction level to its container (not container to parent); subsequent ^ traverse parent chain. Numeric final component targeting a non-container = execution position (Pointer{c, idx}). Exercised by basic_tunnel and factorial tests. No explicit unit tests or same_line_divert_is_inline.ink.json fixture test written yet.

## Final Summary

Implementation was already complete. Added 4 tests covering all ACs: (1) absolute path "f" resolves to the "f" container, (2) relative path ".^.g-0" from inner container finds named child via parent traversal, (3) non-existent path returns null, (4) same_line_divert_is_inline.ink.json → "We hurried home to Savile Row as fast as we could.\n".
