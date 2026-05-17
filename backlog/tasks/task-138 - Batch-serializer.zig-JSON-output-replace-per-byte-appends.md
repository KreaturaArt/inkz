---
id: TASK-138
title: Batch serializer.zig JSON output (replace per-byte appends)
status: To Do
assignee: []
created_date: '2026-05-14 17:43'
labels:
  - compiler
  - performance
dependencies: []
references:
  - src/compiler/serializer.zig
priority: low
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
## Context

`serializer.zig` builds ink.json output using `ArrayList.append()` and `ArrayList.appendSlice()` for individual bytes and small strings — 50+ calls per container. The manual JSON serialization was written for correctness; batching is a follow-up optimization.

Key areas:
- `serializeString()` appends opening `"`, then each character (or escape sequence) individually, then closing `"`
- `writeJsonStr()` (lines 283-293) iterates characters, appending one or two bytes per char
- Integer/float formatting uses `std.fmt.bufPrint` into a stack buffer then `appendSlice` — that part is fine

## Goal

Use a buffered writer (e.g. `std.io.bufferedWriter` wrapping an `ArrayList.writer()`) so individual character appends batch into 4–8KB chunks rather than per-call overhead. Or accumulate into a fixed stack buffer and flush periodically.

Simpler alternative: switch to `std.ArrayList.writer()` + `std.io.bufferedWriter(writer)` at the top of `serializeWithListDefs`, then thread the writer down instead of the ArrayList.

## Acceptance Criteria
<!-- AC:BEGIN -->
- All existing serializer tests pass (same output)
- No behavioral change — output byte-identical to current
- Measurable: `zig build bench` (if bench exists) or unit test timing shows improvement on large stories
<!-- SECTION:DESCRIPTION:END -->

- [ ] #1 All serializer tests pass with byte-identical output
- [ ] #2 serializer.zig uses buffered writes rather than single-byte ArrayList.append() calls
<!-- AC:END -->
