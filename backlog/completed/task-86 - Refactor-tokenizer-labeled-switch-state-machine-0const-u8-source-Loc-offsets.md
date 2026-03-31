---
id: TASK-86
title: >-
  Refactor tokenizer: labeled-switch state machine, [:0]const u8 source, Loc
  offsets
status: Done
assignee: []
created_date: '2026-03-09 17:24'
updated_date: '2026-03-09 18:19'
labels:
  - compiler
  - tokenizer
  - refactor
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The sample/Tokenizer.zig shows idiomatic Zig patterns that improve the tokenizer significantly. Apply these to src/compiler/tokenizer.zig:

**1. Labeled-switch state machine**
Replace `loop: while(true) { ... continue :loop; }` with `state: switch(State.start) { .foo => { ... continue :state .bar; } }`.
This is the idiomatic Zig 0.14+ pattern for tokenizers/state machines — cleaner state transitions, no re-entry confusion.

**2. Null-terminated source `[:0]const u8`**
Change `src: []const u8` to `src: [:0]const u8`. Check `src[pos] == 0` as EOF sentinel instead of bounds-checking `pos >= src.len`. This avoids an extra branch per character.
Update `parse()` entry point in parser.zig to dupeZ the source (or accept `[:0]const u8`).

**3. Token location: `Loc { start: u32, end: u32 }` instead of `text: []const u8`**
Replace `Token.text: []const u8` (fat pointer — 16 bytes) with `Token.loc: Loc { start: u32, end: u32 }` (8 bytes, half the size). Add `pub fn slice(loc: Loc, src: []const u8) []const u8 { return src[loc.start..loc.end]; }` method.
Update parser.zig to call `tok.loc.slice(src)` instead of `tok.text`. Update all test assertions accordingly.

**Acceptance criteria:**
- All existing tokenizer tests pass with new implementation
- All existing parser tests pass (only internal API change)
- Token struct size reduced from 16 → 8 bytes for the loc field
- New unit test verifies `loc.slice(src)` returns correct substring
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 All tokenizer tests pass after refactor
- [ ] #2 All parser tests pass after refactor (API change only, no behavior change)
- [ ] #3 Token.loc is Loc{start,end} not text slice
- [ ] #4 Tokenizer uses labeled-switch (state: switch) not labeled-while
- [ ] #5 Source is [:0]const u8 with 0-sentinel EOF check
<!-- AC:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Rewrote tokenizer.zig with labeled-switch state machine, [:0]const u8 source, and Token.loc Loc{start,end:u32} offsets. Updated parser.zig to dupeZ source, carry src field, and use tok.loc.slice(self.src). All 327 tests pass.
<!-- SECTION:FINAL_SUMMARY:END -->
