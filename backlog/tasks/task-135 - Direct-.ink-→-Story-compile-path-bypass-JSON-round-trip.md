---
id: TASK-135
title: Direct .ink → Story compile path (bypass JSON round-trip)
status: Done
assignee: []
created_date: '2026-05-14 17:42'
updated_date: '2026-05-17 15:01'
labels:
  - compiler
  - performance
  - feature
dependencies: []
references:
  - src/compiler/compiler.zig
  - src/compiler/codegen.zig
  - src/compiler/serializer.zig
  - src/runtime/json_loader.zig
  - src/runtime/story.zig
  - src/runtime/value.zig
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
## Context

Today's in-process compile pipeline is:

```
.ink → tokenizer → parser → codegen (CContainer tree)
     → serializer → [JSON string]          ← wasted work
     → std.json.parseFromSliceLeaky        ← wasted work
     → json_loader → Container[]
     → Story
```

Codegen already produces a structured `CContainer` tree. For in-process use the JSON round-trip (serializer → std.json → json_loader) is pure overhead: allocating strings, writing bytes, then parsing them back. Keep the JSON path for loading external `.ink.json` files (Inklecate compat).

## Goal

Add `compiler.compileToStory(alloc, source) !Story` that goes:

```
.ink → tokenizer → parser → codegen (CContainer)
     → codegen_to_runtime.fromCContainer → Container[]
     → Story
```

`compiler.compile(alloc, source) ![]u8` (JSON) stays unchanged.

## Implementation plan

1. New file `src/compiler/codegen_to_runtime.zig`
   - `pub fn fromCContainer(arena, root: *codegen.CContainer, list_defs: []const Parsed.ListDef) !json_loader.LoadedStory`
   - Recursive traversal mirrors `json_loader.buildContainer()` but takes `CObject` instead of `std.json.Value`
   - Assign container indices in pre-order (same as json_loader does it)
   - Build flat `named_entries[]` table from `CContainer.named_children`
   - Convert `CObject` → `RuntimeObject` per-item (mostly 1:1, see mapping below)

2. `CObject` → `RuntimeObject` mapping (near-complete):
   - `.text` → `.string` (with `^` prefix logic dropped — already raw text)
   - `.newline` → `.string("\n")`
   - `.done` / `.end` → `.control_command(.done/.end)`
   - `.divert` → `.divert {target_path, ...}`
   - `.eval_start/.eval_end/.eval_output` → `.control_command`
   - `.int/.float/.bool_/.string` → corresponding value variants
   - `.var_assign/.temp_assign` → `.variable_assignment`
   - `.var_ref` → `.variable_reference`
   - `.choice_point` → `.choice_point`
   - `.container` → recurse, emit `.container(child_idx)`
   - etc.

3. Handle `list_defs`: `LoadedStory.list_defs_json` is currently `std.json.Value`. Options:
   - Re-serialize just list_defs via serializer (small, cheap)
   - OR change `LoadedStory.list_defs` to a tagged union `JsonListDefs | ParsedListDefs`
   - Simplest: keep the field as `std.json.Value`, re-serialize list_defs only (avoids Story struct change)

4. New entry point in `compiler.zig`:
   ```zig
   pub fn compileToStory(alloc: std.mem.Allocator, source: []const u8) !Story {
       var arena = std.heap.ArenaAllocator.init(alloc);
       const aa = arena.allocator();
       const parsed = try parser.parse(aa, source);
       const root = try codegen.generate(aa, parsed);
       const loaded = try codegen_to_runtime.fromCContainer(aa, root, parsed.list_defs);
       return Story.initFromLoaded(alloc, loaded, arena);
   }
   ```
   Story needs `initFromLoaded(alloc, loaded, arena)` variant that takes pre-built LoadedStory (already does most of this internally).

## Acceptance Criteria
<!-- AC:BEGIN -->
- `compileToStory(alloc, source)` compiles and runs a story identically to `compile()` + `initFromJson()`
- All existing runtime fixture tests pass when using `compileToStory` path
- `compile()` → JSON → `initFromJson()` path unchanged and still passing
- Unit test: compile same source both ways, verify `cont()` output matches
<!-- SECTION:DESCRIPTION:END -->

- [x] #1 compileToStory(alloc, source) exists in compiler.zig and returns a working Story
- [x] #2 All runtime fixture tests pass using compileToStory path
- [x] #3 compile() JSON path unchanged and all existing tests still pass
- [x] #4 Unit test verifies both paths produce identical cont() output for at least 3 fixture stories
<!-- AC:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
## What was done

Added a direct `.ink → Story` compile path that skips JSON serialization/deserialization entirely.

### New files
- **`src/compiler/codegen_to_runtime.zig`**: Converts a `CContainer` tree (codegen output) directly to `Container[]` + `NamedEntry[]` without going through JSON. Mirrors `json_loader.buildContainer` exactly but takes `CObject` instead of `std.json.Value`. Also provides `buildListDefs()` to construct `ListDefinitionsOrigin` from `Parsed.ListDef[]`.

### Modified files
- **`src/compiler/compiler.zig`**: Added `compileToStory(alloc, source) !Story`. The existing `compile()` returning JSON is unchanged. Renamed `story` local to `parsed_story` to avoid shadow.
- **`src/runtime/story.zig`**: Added `initFromContainers(allocator, arena, containers, named_entries, list_defs) !Story` — the shared init path that `compileToStory` uses. Identical setup to `initFromJson` (visit counts, hot-path pre-alloc, global decl execution) without the JSON parsing.
- **`src/root.zig`**: Exported `codegen_to_runtime` module and added it to the test block.

### CObject → RuntimeObject mapping
All 28 CObject variants map directly to RuntimeObject equivalents. `CObject.string` goes through `convertString()` which mirrors `json_loader.parseStringObject` (handles control commands, native functions, plain strings).

### Tests added
- 3 unit tests in `codegen_to_runtime.zig`: `buildListDefs` (empty + with items), `convert hello world` (structure match), path assignment match
- 4 integration tests in `compiler.zig`: hello world, arithmetic, knot divert, VAR global — each compiles both ways and asserts `cont()` output is identical

All 549 tests pass.
<!-- SECTION:FINAL_SUMMARY:END -->
