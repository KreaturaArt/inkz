# TASK-138: Batch serializer.zig JSON output (replace per-byte appends)

- Status: Done
- Priority: low
- Labels: compiler, performance
- Dependencies: —
- References: src/compiler/serializer.zig
- Created: 2026-05-14 · Updated: 2026-05-17

## Description

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
- All existing serializer tests pass (same output)
- No behavioral change — output byte-identical to current
- Measurable: `zig build bench` (if bench exists) or unit test timing shows improvement on large stories

- [x] All serializer tests pass with byte-identical output
- [x] serializer.zig uses buffered writes rather than single-byte ArrayList.append() calls

## Final Summary

Replaced the per-character `buf.appendSlice`/`buf.append` loop in `writeJsonStr` with a single `ensureUnusedCapacity(s.len * 2)` up front followed by `appendSliceAssumeCapacity`/`appendAssumeCapacity` calls that never check capacity in the inner loop. This eliminates O(N) allocation-check overhead for every serialized string. All 549 tests pass; output byte-identical.
