# Fuzzing

Every stage of the pipeline has its own fuzz target (plan Phase 11), built on Zig's
integrated fuzzer: `std.testing.fuzz` with `std.testing.Smith` input. Most targets build
their input with structure, so that what reaches a stage has already passed the stages
before it. Random bytes would mostly stop at the first check.

- **Ink-based targets.** These use the ink source generator `src/testing/fuzz_ink.zig`. The
  fuzzer's choices pick each construct: knots, stitches, functions, declarations, weave,
  diverts, tunnels, threads, conditionals and expressions. All names come from a small pool
  that the generator declares, so about 70% of the sources compile.
- **Loader targets.** These start from a valid file (a program image, a story's JSON or a
  save) and let the fuzzer edit its words or tokens.

## Running

```sh
zig build fuzz                                          # every target once, on its seed corpus
zig build fuzz -Doptimize=ReleaseSafe --fuzz=100K -Dtest-filter="<filter>"
```

`zig build fuzz` runs each target once, on its seeds. It also checks 32 seeded generated
inputs per target with the same invariants, so it works as a regression test.

`--fuzz=N` starts the coverage-guided fuzzer. It stops after about N inputs and prints the
runs, the unique runs and the coverage. Its corpus is kept in `.zig-cache/f`, so the counts
add up across runs. When an input crashes, it is saved to `.zig-cache/f/crash`. To replay
it, call the target's check function in a test with `Smith{ .in = @embedFile("crash.bin") }`.

**Build with `-Doptimize=ReleaseSafe`.** It keeps every assert and is about 20 times faster
than Debug. The compiler and runtime targets need that speed: a 100K run takes one to two
minutes.

The coverage figures below count the whole test binary, compiler and runtime included. They
compare runs of one target, not targets with each other.

## Targets

| Stage | File | Filter | Input | Checks |
|---|---|---|---|---|
| Comment removal | `src/fuzz/source.zig` | `comment removal` | bytes weighted toward `/`, `*`, newlines | output no longer than the input and a subsequence of it; every line kept |
| INCLUDE discovery | `src/fuzz/source.zig` | `INCLUDE discovery` | 4 fuzzer-written files of INCLUDEs (chains, cycles, missing files), with tight bounds | a space or an error; files form a tree within the depth and file bounds, laid end to end |
| Tokenizer | `src/fuzz/tokenizer.zig` | `contiguous and repeatable` | bytes weighted toward ink punctuation and UTF-8, in fuzzer-chosen modes, with checkpoint rewinds | tokens contiguous and non-empty; eof at the end; a token read again is the same |
| Tokenizer (raw) | `src/fuzz_targets.zig` | `ends in every mode` | raw bytes | the stream ends |
| Parser | `src/fuzz/parser.zig` | `well-formed tree` | generated ink with raw bytes spliced in | a tree or an error; every node reached once, with a valid shape and in-range tokens |
| Sema and resolve | `src/fuzz/sema.zig` | `consistent tree` | generated ink that parses | every object is its parent's child exactly once; the resolution is in range |
| Lower and emit | `src/fuzz/lower.zig` | `survive their JSON` | generated ink | `Program.check`; compiling twice gives the same image; serialize then load gives the same image |
| Compiler (raw) | `src/fuzz_targets.zig` | `compiler never crashes` | raw bytes | a program or an error |
| JSON loader | `src/fuzz/json.zig` | `mutated ink JSON` | a compiled story's JSON with its tokens edited | a checked program or an error |
| JSON loader (raw) | `src/fuzz_targets.zig` | `JSON loader never crashes` | raw bytes | a checked program or an error |
| Program image | `src/fuzz_targets.zig` | `mutated program image` | a valid image with words, bytes and bits changed and the length cut | a checked program or a named error |
| Program image (raw) | `src/fuzz_targets.zig` | `image loader never crashes` | raw bytes | a checked program or a named error |
| VM | `src/fuzz/vm.zig` | `keeps the state consistent` | generated stories played with the fuzzer's seed, bindings and choices | `state.check` after every call |
| Save and load | `src/fuzz/save.zig` | `loaded save plays` | a played story's save, loaded into a fresh story; the save with its tokens edited | the same save JSON and the same transcript; an edited save leaves the story unchanged or checked |
| Save loader (raw) | `src/fuzz_targets.zig` | `save loader never crashes` | raw bytes | the state is unchanged or checked |
| Host API | `src/fuzz/host.zig` | `host calls` | up to 48 API calls in any order, with names and values in the pool and outside it | a result or an error; `state.check` after each call |

Shared pieces:

- `src/fuzz/play.zig` compiles a generated story and sets it up. The fuzzer picks the random
  seed, the external fallback rule and whether `e0` is bound.
- It also gives runtime stories a budget of 10,000 steps per `cont`. Generated stories loop,
  and the default budget of 1,000,000 made each input slow.

## Results (2026-11-13)

All runs used ReleaseSafe unless noted. None crashed once the bugs below were fixed.

| Target | Runs | Unique | Coverage |
|---|---:|---:|---:|
| Comment removal (Debug) | 200,103 | 100 | 72 / 9,127 |
| INCLUDE discovery (Debug) | 244,495 | 264 | 1,574 / 11,331 |
| Tokenizer | 200,844 | 773 | 224 / 9,260 |
| Tokenizer, raw (Debug) | 200,593 | 513 | 201 / 9,232 |
| Parser (Debug) | 110,665 | 2,778 | 1,986 / 11,065 |
| Sema and resolve (Debug) | 112,863 | 4,504 | 2,880 / 13,024 |
| Lower and emit | 125,641 | 2,692 | 5,544 / 17,393 |
| JSON loader | 101,584 | 1,430 | 2,114 / 17,293 |
| JSON loader, raw | 100,670 | 668 | 511 / 11,472 |
| Program image (Debug) | 318,443 | 306 | 1,173 / 16,905 |
| Program image, raw (Debug) | 200,086 | 83 | 28 / 16,908 |
| VM | 51,317 | | 6,847 / 19,897 |
| Save and load | 102,074 | 1,377 | 7,877 / 21,827 |
| Host API | 103,302 | 2,686 | 7,959 / 21,539 |

## What the targets found

| Target | Finding | Fix |
|---|---|---|
| Tokenizer | `peek` returns 0 past the end, so a 0 byte inside the source ended the text with an empty token. In Debug, a `.ink` file with a NUL byte crashed the compiler. The old targets cut their input at the first 0, which hid this. | A 0 byte is text (`tokenizer.zig`, unit test "a 0 byte inside the source is text, not the end"). |
| JSON loader | A content object with an empty key (`{"":"$r"}`) reached an assert. | `error.InvalidInkJson`; the cases are in "malformed input returns an error instead of crashing". |
| Save and load | A limit or host error in the newline lookahead left the snapshot active, and saving then asserted. | The story goes back to its last line (`Story.fail_step`). |
| Host API | After a limit error in the middle of a step, the next `cont` ran on from the half-done state and asserted in `end_string`. | The story fails closed with `error.StoryFailed` until `reset_state` or `load_json` (see `docs/RunningYourInk.md`). |

Two of the first assumptions turned out wrong; the parser was correct both times:

- Marker nodes (`newline`, `tag_end`, `empty_divert`) hold a source offset, not a token.
- Token starts aren't in order, because a peek rewinds the input but keeps its tokens.

One difference is ink's own behaviour, and inkz keeps it. ink's save doesn't keep a
choice's `isInvisibleDefault` (`JObjectToChoice` in `JsonSerialisation.cs`), so a pending
fallback choice becomes visible after a load, in C# ink and here. The save target therefore
doesn't compare such saves.
