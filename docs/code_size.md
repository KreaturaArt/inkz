# Code size

`zig build code-size` (tools/code_size.zig) counts the lines of Zig per module: code,
comments, top-level `test` blocks and blank lines.

## Phase 13: reading like handwritten code (2026-11-14)

A review on 2026-11-13 estimated each module against a careful handwritten version with the
same behaviour and design. Phase 13 then deleted dead code, merged duplicates, dropped
ticket ids and new/old names from comments, and replaced filler assertions. The density
rule was relaxed to at least one assertion per function in library code, with none required
in tests and tools, so the remaining assertions state real preconditions and invariants.

Code lines, without comments, tests and blank lines. Before is commit 29ba8bb; after is the
end of Phase 13.

| Module | Code before | Code after | Change | Tests before | Tests after |
|---|---:|---:|---:|---:|---:|
| src/core | 4,891 | 4,451 | −9% | 1,002 | 924 |
| src/runtime | 8,532 | 8,005 | −6% | 1,371 | 1,395 |
| src/compiler | 9,234 | 8,209 | −11% | 1,264 | 1,218 |
| src/testing | 3,133 | 2,917 | −7% | 2,282 | 1,266 |
| src/fuzz | 796 | 706 | −11% | 98 | 90 |
| src (roots, benches) | 1,495 | 1,363 | −9% | 120 | 115 |
| tools | 1,052 | 1,169 | +11% | 397 | 440 |
| build.zig | 292 | 261 | −11% | 0 | 0 |
| sample | 1,462 | 0 | −100% | 161 | 0 |
| **Total** | **30,887** | **27,081** | **−12%** | **6,695** | **5,448** |

Code and tests together: 37,582 → 32,529 lines (−13%). Tools grew by the code-size and CI
checks.

The review estimated about −28%. Most of the gap is items left out because they would have
changed output or risked more than they saved:

- **Builtin tables.** Resolution treats `_` as a builtin and lowering doesn't, so merging
  their tables would change how `_()` compiles.
- **END/DONE and list items.** Passing these from resolution to lowering needs new
  per-divert data in the resolution.
- **heap.zig.** Its string and list paths look alike, but they use different layouts (a
  mark bit and byte offsets against a forward word and word offsets).
- **"transcripts are up to date".** It replays every fixture a second time, and was kept.

Assertions in library code went from about two per function, many repeating a structure's
invariant in every function, to at least one per function. Each structural invariant is
stated once, where it is established. One file, `src/compiler/grammar.zig`, is allowed below
the density: its one-line StringParser primitives have no precondition of their own, and the
parser machine checks the input once per step.

Speed, measured alternately against the end of Phase 12 (ReleaseFast, best of several runs
on the same machine): play, story init, JSON and image load and store, and saves are
unchanged, within ±3%. Compiling is about 3% slower. The shared tree walker cost 6% until it
took its order at compile time and kept its first levels in place; the rest comes with the
added preconditions.
