# TASK-17: Temporary variables and callstack scoping

- Status: Done
- Priority: high
- Labels: layer-4, variables
- Dependencies: —
- Created: 2026-02-23 · Updated: 2026-03-01

## Description

Implement temporary variable scoping in `src/runtime/variables.zig` and `src/runtime/callstack.zig`.

- `.variable_assignment` with `is_global==false` (temp=): store in `currentElement().temporary_variables`
- VAR? resolution order: search `temporary_variables` on each callstack element top-to-bottom, then fall back to globals
- On `pop()` of a callstack element, its `temporary_variables` are deinit'd (discarded)

Tests:
- Unit: push function frame, assign temp `"t"=42`; lookup finds `.int(42)`
- Unit: pop the frame; lookup for `"t"` falls through to globals; returns `null` if not in globals
- Unit: temp in inner frame shadows global with same name; after pop, global value restored
- `callstack/callstack_evaluation.ink.json` → determine expected output by inspecting the `.ink` source before writing the test

## Acceptance Criteria
- [x] Temp var found in current callstack frame
- [x] After pop, temp var no longer visible
- [x] Temp shadows global of same name within frame
- [x] callstack_evaluation.ink.json produces correct output (verify expected string before implementing)

## Implementation Notes

Implementation complete in src/runtime/story.zig and variables.zig. temp= stores in currentElement().temporary_variables; VAR? resolution order searches temp frames top-to-bottom before globals; popped frame's temps are deinit'd. Exercised implicitly by factorial_recursive test (uses temp vars for recursion). No explicit unit tests for temp var scoping or callstack_evaluation.ink.json fixture test written yet.

## Final Summary

Implementation was already complete. Added 3 unit tests and 1 fixture test: (1) temp var found in pushed frame, (2) temp gone after pop + global falls through as null, (3) temp shadows global in frame / global restored after pop, (4) callstack_evaluation.ink.json → "8\n" (six()+two() = recursive function chain). Made resolveVariable pub to enable unit testing.
