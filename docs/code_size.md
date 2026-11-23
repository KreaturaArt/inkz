# Code size

`zig build code-size` (tools/code_size.zig) counts the lines of Zig per module: code,
comments, top-level `test` blocks and blank lines.

## Phase 17: code-bloat reduction (2026-11-23)

A review on 2026-11-22 compared each module with a careful handwritten version of the same
features again, this time allowing API changes, different error wording and more memory
where they remove a lot of code. Phase 17 took those cuts. Every behaviour that was checked
before is still checked (ground truth, transcripts, structure gate, api and fuzz corpus).

Code lines, without comments, tests and blank lines, counted by this tree's
tools/code_size.zig on both trees (the tool changed in P17.6; it gives the same counts for
main as main's own copy). Before is main (873eb9b); after is the end of Phase 17 (1ff6dad).
Main includes Phases 14 to 16, so its numbers are higher than the Phase 13 ones below.

| Module | Code before | Code after | Change | Tests before | Tests after |
|---|---:|---:|---:|---:|---:|
| src/core | 4,750 | 3,963 | −17% | 1,129 | 1,210 |
| src/runtime | 8,535 | 6,950 | −19% | 1,533 | 1,492 |
| src/compiler | 10,077 | 9,374 | −7% | 1,968 | 2,049 |
| src/testing | 4,513 | 3,870 | −14% | 2,409 | 2,446 |
| src/fuzz | 1,069 | 1,054 | −1% | 273 | 225 |
| src (roots, bench, dev tool) | 1,626 | 1,411 | −13% | 92 | 92 |
| tools | 1,245 | 960 | −23% | 472 | 404 |
| build.zig | 315 | 304 | −3% | 0 | 0 |
| **Total** | **32,130** | **27,886** | **−13%** | **7,876** | **7,918** |

Code and tests together: 40,006 → 35,804 lines (−10%), in 143 → 131 files. Comments went
from 3,720 to 3,644 lines. Tests grew slightly: several cuts added a unit test for the code
that replaced the old one. The review estimated −18% with design-preserving cuts and −25%
with the bold ones; the gap is mostly the items below that were tried and dropped.

What was done:

- **Testing (P17.1, P17.4, P17.5).** The oracle is a line-by-line snapshot comparison; the
  ledger and known_bugs go, and the transcripts are replayed once per test run. One shared
  play helper, case iterator and fuzz wrapper. E2e stories play once, and 139 fixture rows
  that ground truth already covers go.
- **Tools and build (P17.2, P17.3, P17.6).** One bench program with subcommands, one dev
  tool instead of five executables, build steps from two tables, the lint's recursion
  check as a back-edge DFS instead of Tarjan SCC.
- **Core (P17.7 to P17.10).** The builder takes divert kinds, external calls and variable
  pointers directly, without the JSON-key round trip or its diagnostics list. One Program
  validator. One string pool type, extra records as extern structs. The JSON reader reads
  keys through one helper; dead code and program_dump go.
- **Runtime (P17.11 to P17.16).** api.zig merges into story.zig. Save loading parses with
  std.json in one pass and json_tree.zig goes. The lookahead copies 64-slot chunks on
  first write instead of keeping an undo log. Each flow owns its buffers, so the parking
  region goes. The heap compacts only between instructions, so keep lists go. Diagnostics
  are formatted when raised, so the Code enum and messages.zig go.
- **Compiler (P17.17 to P17.21).** One builtin table; resolution decides each divert's kind
  and list items. The IR uses core Opcode and stores each Item whole. The object tree is a
  MultiArrayList with one AST walker. Each INCLUDE file is parsed once. The parser loses
  `.again` and most phase-step scaffolding.
- **Assertions (P17.23).** The density rule is per module (one per three functions in a
  library file). About 930 ceremonial assertion lines go (1,907 → 973 assertion calls),
  keeping preconditions, size guards, the check()/Fault functions and each invariant once
  where it is established.

Tried and dropped:

- **Shunting-yard expressions and combinator rules (P17.22).** The shunting-yard prototype
  was behaviour-identical but came out at +2 lines; combinator descriptors would cost about
  45 lines of machinery to save about 24; building the object tree in the parser has no
  low-risk path. Nothing was kept.
- **Arena per Program (P17.10).** About −40 lines, but the compiler's peak memory went from
  245 to 314 KB (over its pinned limit), fitted program bytes grew 47% from arena slack, and
  compiling the 1000-knot story went from 19 to 28 ms. Reverted.
- **Fewer play loops (P17.4).** The harness, fuzz play, simulation and bench keep their own,
  as each needs a different hook.
- **A plain full lookahead copy (P17.13).** It cost 23% of play on the 1000-knot story, so
  the copy is chunked copy-on-write, and the cut is −114 lines instead of −180.
- **INCLUDE parse once (P17.20)** was about break-even in lines (−4 instead of −70); it was
  kept because each file is now parsed once.

Trade-offs taken:

- **Memory.** The default budget (`Limits.bytes_total` at the default limits, empty
  program) went from 2,206,464 to 3,974,432 bytes (+80%): each of the 8 default flows owns a
  full set of buffers (+0.98 MB, P17.14; `flows_max = 1` or fitted limits take it back), the
  save-load scratch is a 1 MiB std.json arena instead of 256 KiB of tokens (+768 KiB,
  P17.12), and diagnostics keep 256 message bytes each (P17.16). Fitted budgets grew much
  less: crime_scene 88,037 → 105,889 bytes, the 1000-knot story 758,891 → 789,031 (program
  plus state). See docs/benchmarks.md, Phase 17.
- **Compiler peak memory.** Mostly because the IR stores each Item whole (P17.18), the peak
  rose from 230 to 244 KB for crime_scene in ReleaseFast and from 4.29 to 4.89 MB for the
  1000-knot story; the memory limit test is re-pinned.
- **Behaviour.** A failed `load_json` leaves the story as `reset_state` leaves it, instead
  of untouched (P17.12). Each flow keeps its own count of indexed choices, as ink's parked
  flows do, and a flow switch can no longer fail (P17.14). `_()` is a native call, as in
  ink, where it used to fail an assertion in lowering (P17.17).
- **Error names.** `error.FlowParkingLimit` and `error.LookaheadLogLimit` are gone with
  their limits (`flow_parking_bytes_max`, `patch_entries_max`); `evaluate_function`'s
  output stash has its own `output_stash_bytes_max` and `error.OutputStashLimit`;
  `load_nodes_max` became `load_bytes_max`. Some Program faults have new names (P17.8).
  Runtime messages keep ink's text.

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
  their tables would change how `_()` compiles. (P17.17 merged them: `_()` failed an
  assertion in lowering, and ink compiles it as a native call.)
- **END/DONE and list items.** Passing these from resolution to lowering needs new
  per-divert data in the resolution. (P17.17 added it: each divert's kind, and each list
  literal's items.)
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
