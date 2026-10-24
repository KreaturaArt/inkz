# TASK-16: Global variable assignment and reference

- Status: Done
- Priority: high
- Labels: layer-4, variables
- Dependencies: —
- Created: 2026-02-23 · Updated: 2026-03-01

## Description

Handle variable_assignment (VAR=) and variable_reference (VAR?) in step(). Global initialization block. 

Tests: const.ink.json produces correct output

## Acceptance Criteria
- [x] VAR= stores value in globals
- [x] VAR? pushes value to eval stack
- [x] Global init block runs before content

## Implementation Notes

Implemented in src/runtime/story.zig. VAR= pops eval stack and stores in globals; VAR? looks up via resolveVariable (searches temp frames first, then globals). Global decl container (named_content.get("global decl")) is executed at initFromJson time before any content. Verified by test 29 (Story const variable → "5\n").
