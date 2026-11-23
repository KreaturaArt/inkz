# Fuzzing

Every stage of the pipeline has its own fuzz target (plan Phase 11), built on Zig's
integrated fuzzer: `std.testing.fuzz` with `std.testing.Smith` input. Most targets build
their input with structure, so that what reaches a stage has already passed the stages
before it. Random bytes would mostly stop at the first check.

- **Ink-based targets.** These use the ink source generator `src/testing/fuzz_ink.zig`. The
  fuzzer's choices pick each construct: knots, stitches, functions, declarations, weave,
  diverts, tunnels, threads, conditionals and expressions. All names come from a small pool
  that the generator declares, so every source compiles unless its swarm turns on one of the
  two error features: `drop` leaves declarations, knots and functions out while terms still
  name them, and `collision` declares a name ink rejects. Each is drawn 1 in 8, so about 89%
  of the swarm's sources compile.
- **Swarm testing.** Each generated source first draws a configuration (`Swarm` in
  `fuzz_ink.zig`, after Groce et al., "Swarm Testing", ISSTA 2012): the line kinds, terms,
  operators, inline constructs, divert targets and declarations it may use, and its bounds
  (lines per weave, terms per expression, choice depth, knots). Each feature is on with
  probability ½, and one draw in 8 is `Swarm.all`, the full mix. Leaving features out of a
  whole source makes the rest dense and keeps suppressors such as an early `-> END` out of
  the configurations that need depth. The generator picks only enabled features, with no
  retries. `Swarm.format` writes a configuration as one line and `Swarm.parse` reads it
  back, for failure reports and reproduce commands. `Swarm.classic` (the full mix with
  `drop`) takes the same choices as the generator before swarms, so its seeds still give the
  same sources; `Swarm.all` is the full mix without the error features.
- **Stories that play long.** Two swarm features shape a source for the play targets. With
  `hub` (drawn 3 in 4), the root diverts to a knot `hub` of choices, and every knot ends in
  a block of mostly sticky choices that divert to the hub and the knots, so play loops
  through choices; other choices follow a sticky fallback to the hub, tunnels call a knot
  that only tunnels reach, and diverts and threads outside choices only go forward. With
  `typed` (drawn 1 in 2), each expression keeps to numbers, strings or lists, with the
  operators ink defines on them, so type errors don't stop play. Neither is in
  `Swarm.classic`.
- **More of ink.** The swarm's `constructs` (P18.6, each drawn 1 in 2, none in
  `Swarm.classic`) are what the first generator didn't write: `TURNS()`, the math functions
  (`POW`, `FLOOR`, `CEILING`, `INT`, `FLOAT`, `MIN`, `MAX`), the list functions
  (`LIST_VALUE`, `LIST_MIN`, `LIST_MAX`, `LIST_ALL`, `LIST_INVERT`, `LIST_RANDOM`,
  `LIST_RANGE`, `l0(n)`), `~ SEED_RANDOM(n)`, the one-condition multi-line conditional with
  `- else:`, tags on choices (in each part of the text, one with a value), a variable that
  holds a divert target and is diverted to (`VAR d0 = -> k0`, `-> d0`), and knots with
  parameters reached by tunnels, threads and diverts with arguments (`-> tunnel1(n) ->`,
  `<- thread1(n)`, `-> jump1(n, -> k0)`, whose `-> t` diverts to its parameter). Sticky
  and fallback choices and the multi-branch conditional with `else` were there already.
  With `hub`, `d0` and `jump1`'s target always hold the hub, so nothing loops without a
  choice. A differential run of 2,400 drawn stories and 400 of `Swarm.all` against ink found
  no divergence in them. The host target found a bug with them: `evaluate_function` of a
  knot with parameters and no arguments pops the values a story error left on the
  evaluation stack, below its own frame, and inkz asserted; it now reports a story error
  (ink returns null with the values gone; `host_api_test.zig`, "evaluate_function of a knot
  with more parameters than arguments fails closed"). `--target all --seconds 60` from seed
  1 then ran 25,821 play, 16,036 save and 27,776 host seeds without a failure (play: 2,812
  compile failures, 4,861 runtime errors, 458,046 lines, 325,496 choices).
- **Larger stories, flows and files (P19.4).** One drawn subset in 16 is *large*: up to
  32 lines a flow, 8 terms an expression and 6 levels of weave, and its weaves and
  expressions go on longer (a flow otherwise ends after 4 lines on average), so its stories
  have 2.6 times the bytes (2,690 against 1,033 on average over 2,000 draws; the longest
  7,399). `Swarm.classic` doesn't change. The swarm runner's plans (not `Swarm` features,
  so the triage doesn't see them) add the rest: each play gets a step cap of 64 or, half
  the time, 4 to 256 calls; a quarter of the plays switch to the flows `one` and `two`, back
  to the default flow, or remove one, before 1 call in 8 (a new flow starts at the top of the
  story); and a quarter of the stories of the compile, play and save targets are also
  compiled from 2 or 3 files in memory (`compile.compile_files_with`): the root in
  `main.ink`, ended by `-\n-> DONE` before its INCLUDEs, the knots in `part1.ink` and, from
  a drawn later knot, `part2.ink`, included from `main.ink` or from `part1.ink`. They must
  compile, or fail with the same first error, as the one source they join to, and play the
  same. The root ends with a divert because ink ends each INCLUDE's content with a newline
  (`PreProcessTopLevelObjects`) that joins the weave where the INCLUDE stands: after a
  choice it goes into the choice's body and drops its divert to the gather (inklecate
  does the same; inkz matches it), and at the top it moves the paths that runtime errors
  name. 1 in 8 of the splits also includes a missing file or main.ink again, and must fail
  with `include_not_found` or `include_cycle`.
- **Loader targets.** These start from a valid file (a program image, a story's JSON or a
  save) and let the fuzzer edit its words or tokens.

## Running

```sh
zig build fuzz                                          # every target once, on its seed corpus
zig build fuzz -Doptimize=ReleaseSafe --fuzz=100K -Dtest-filter="<filter>"
```

`zig build fuzz` runs each target once, on its seeds. It also checks 32 seeded generated
inputs per target with the same invariants, so it works as a regression test; the
generating targets share this through `fuzz_ink.run_target(check, passed_min)`.

`--fuzz=N` starts the coverage-guided fuzzer. It stops after about N inputs and prints the
runs, the unique runs and the coverage. Its corpus is kept in `.zig-cache/f`, so the counts
add up across runs. When an input crashes or fails a check, it is saved to
`.zig-cache/f/crash` and the fuzzing stops with `error: test '...' exited with code 1;
input saved to '.zig-cache/f/crash'`, but **`zig build` still exits 0** (Zig 0.17.1), so a
script must look for that line or the file. To replay the input, call the target's check
function in a test with `Smith{ .in = @embedFile("crash.bin") }`.

**Build with `-Doptimize=ReleaseSafe`.** It keeps every assert and is about 20 times faster
than Debug. The compiler and runtime targets need that speed: a 100K run takes one to two
minutes.

The coverage figures below count the whole test binary, compiler and runtime included. They
compare runs of one target, not targets with each other.

### In CI

`.github/workflows/fuzz.yml` fuzzes each target of the table below for a bounded number of
inputs, on every push to main, every night and on demand (`workflow_dispatch`, with an
optional `runs` for every target). Each target is a job of its own on ubuntu-latest, so the
targets run side by side and a crash names its target; a job is capped at 15 minutes and
its fuzz step at 12. The step runs

```sh
zig build fuzz -Doptimize=ReleaseSafe --fuzz=<runs> -Dtest-filter="<filter>"
```

and fails when `.zig-cache/f/crash` exists or the log has an `error:` line, because the
build's exit code doesn't say. A failed job uploads `crash.bin`, the fuzzer's
`libfuzzer.log`, the step's log and the target and bound as the artifact
`fuzz-crash-<target>-<run id>` (kept 30 days). The corpus isn't kept between runs: its
directory is named by a hash of the binary's coverage points, which changes with the code.

The bounds give each target about a minute locally (an M-series Mac, ReleaseSafe, the build
included; lower and VM at 20K and save, host and limits from a fresh corpus, the others
after a 20K run had filled theirs). A runner about half as fast takes two to four minutes; the first runs
on GitHub will tell.

| Target | Filter | Runs | Local |
|---|---|---:|---:|
| Comment removal | `comment removal` | 200K | 15 s |
| INCLUDE discovery | `INCLUDE discovery` | 200K | 58 s |
| Parser | `well-formed tree` | 100K | 45 s |
| Sema and resolve | `consistent tree` | 50K | 38 s |
| Lower and emit | `survive their JSON` | 20K | 98 s |
| Compiler (raw) | `compiler never crashes` | 200K | 49 s |
| JSON loader | `mutated ink JSON` | 100K | 48 s |
| JSON loader (raw) | `JSON loader never crashes` | 200K | 18 s |
| Program image | `mutated program image` | 200K | 25 s |
| Program image (raw) | `image loader never crashes` | 200K | 22 s |
| VM | `keeps the state consistent` | 25K | 76 s |
| Save and load | `loaded save plays` | 15K | 74 s |
| Save loader (raw) | `save loader never crashes` | 100K | 49 s |
| Host API | `host calls` | 40K | 46 s |
| Limits | `limits drawn` | 30K | 47 s |

The raw image and comment targets saturate early (26 and 125 coverage points), so more runs
would add nothing. The first timing run, at 20K each, found a bug in the save target within
10,382 inputs (see "What the targets found").

## Targets

| Stage | File | Filter | Input | Checks |
|---|---|---|---|---|
| Comment removal | `src/fuzz/source.zig` | `comment removal` | bytes weighted toward `/`, `*`, newlines | output no longer than the input and a subsequence of it; every line kept |
| INCLUDE discovery | `src/fuzz/source.zig` | `INCLUDE discovery` | 4 fuzzer-written files of INCLUDEs (chains, cycles, missing files), with tight bounds | a space or an error; files form a tree within the depth and file bounds, laid end to end |
| Parser | `src/fuzz/parser.zig` | `well-formed tree` | generated ink with raw bytes spliced in | a tree or an error; every node reached once, with a valid shape and in-range tokens |
| Sema and resolve | `src/fuzz/sema.zig` | `consistent tree` | generated ink that parses | every object is its parent's child exactly once; the resolution is in range; with reference errors, lowering still runs for its diagnostics and the compile delivers an error |
| Lower and emit | `src/fuzz/lower.zig` | `survive their JSON` | generated ink | `Program.check`; compiling twice gives the same image; serialize then load gives the same image; a failed compile delivers at least one error |
| Compiler (raw) | `src/fuzz_targets.zig` | `compiler never crashes` | raw bytes | a program or an error |
| JSON loader | `src/fuzz/json.zig` | `mutated ink JSON` | a compiled story's JSON with its tokens edited | a checked program or an error |
| JSON loader (raw) | `src/fuzz_targets.zig` | `JSON loader never crashes` | raw bytes | a checked program or an error |
| Program image | `src/fuzz_targets.zig` | `mutated program image` | a valid image with words, bytes and bits changed and the length cut | a checked program or a named error |
| Program image (raw) | `src/fuzz_targets.zig` | `image loader never crashes` | raw bytes | a checked program or a named error |
| VM | `src/fuzz/vm.zig` | `keeps the state consistent` | generated stories played with the fuzzer's seed, bindings and choices | `state.check` after every call |
| Save and load | `src/fuzz/save.zig` | `loaded save plays` | a played story's save, loaded into a fresh story; the save with its tokens edited | the same save JSON and the same transcript; an edited save loads checked or leaves the story reset |
| Save loader (raw) | `src/fuzz_targets.zig` | `save loader never crashes` | raw bytes | the state is checked, or reset as `reset_state` leaves it |
| Host API | `src/fuzz/host.zig` | `host calls` | up to 48 API calls in any order from the session's drawn call set, with names and values in the pool and outside it | a result or an error; `state.check` after each call |
| Limits | `src/fuzz/limits.zig` | `limits drawn` | generated stories and a host call mix under limits drawn per field: the default, or tight (1 to 16 of a count, 256 to 4,096 bytes) | a result or an error; `state.check` after each call; a story that failed in the middle of a step answers `cont` with `error.StoryFailed` |

Swarms beyond the generator (plan §3.5):

- **Host calls.** Each session draws its call set (`host.draw_calls`): the full set with
  weight 1/8, else each call with probability ½, and `cont` always. `reset` and
  `save_and_load` wipe or rebuild the state, so sessions without them reach depth.
- **Limits.** The limits target draws every `Limits` field as its default or tight, and
  compact-always as a feature. It also checks the **budget property** on 64 seeds: a run
  that hit no limit, replayed under `Limits.fitted(usage, 1)`, makes the same calls with the
  same errors. The property first failed: the heap's peak counted the bytes used, not the
  room `ops.reserve` asks for before an operation (the worst case of a float's text), so a
  fitted heap of 28 bytes failed the reservation. The heap's and the list slab's peaks now
  include reservations (`note_need`).
- **Simulator.** `zig build simulate -- --swarm on` draws an action mix per seed
  (`simulation.Mix.draw`): each of save and load, a flow switch and back, `set_variable`,
  `evaluate_function` and `choose_path_string` on with probability ½ and a weight of 1 to 20
  per 100 turns, and compact-always with probability ½. `Mix.full` is the mix before swarms.
  A failure prints `--swarm-config <hex>`, which replays its mix. `--seeds 10000 --swarm on`
  (ReleaseSafe): 1,880,000 runs, 0 failures, 37 s.

- **Loader mutations** (plan §3.6). Each mutated input draws its operators
  (`fuzz_ink.draw_subset`). For a program image (`src/fuzz/image.zig`) they are: a word set
  to any value or to a boundary (0, 1, the largest index, `none`, a heap reference's bit,
  all ones), a word copied from elsewhere in the image, two neighbouring words swapped, a
  byte, a bit, and truncation. A set with only the copy builds cross-wired but plausible
  records for `decodable` and `Program.check` to reject. For ink JSON and saves
  (`src/fuzz/json.zig`, used by `src/fuzz/save.zig`) they are the token edits plus a
  boundary number, a pool name and a renamed object key. 100K ReleaseSafe runs each (image
  101,487, JSON 102,068, save 106,615): no crash.

Shared pieces:

- `src/fuzz/play.zig` compiles a generated story and sets it up. The fuzzer picks the random
  seed, the external fallback rule and whether `e0` is bound.
- It also gives runtime stories a budget of 10,000 steps per `cont`. Generated stories loop,
  and the default budget of 1,000,000 made each input slow.

## Long seeded runs and triage

`zig build swarm -Doptimize=ReleaseSafe -- --target <compile|play|save|host|mutate|all> --seed S --seeds N`
(or `--seconds T` instead of `--seeds`: as many seeds as fit; `all` is `play`, `save`,
`host` and `mutate`, with 4, 3, 3 and 2 twelfths of the time. CI runs `--target all --seconds 300` after `zig build ci` passes, and the
hk pre-push hook in `hk.pkl` runs `--seconds 10`; `hk install` once per clone)
(`src/testing/swarm_runner.zig`) runs seeded swarm cases out of the fuzzer: each seed draws a
configuration and a generated story, and the target checks it. Every target checks the
compiled program (`check_program`): it passes `Program.check`, and compiled a second time,
serialized to JSON and loaded (`ink_json.serialize`, `ink_json.load`), and written to an
image and loaded (`program_image`), it is the same program, every array element by element
(`program_testing.first_difference`, which the structural gate uses too). `compile` does
only that, so `all` leaves it out. `play` plays it with seeded choices and checks the
state after every call; each seed binds `e0`, allows its fallback, both or neither (as the
fuzz targets' `Setup` does), and draws the story's random seed. It then plays the seed a
second time under the first play's fitted limits (`Limits.fitted(usage, 1)`), under tight
limits drawn as the limits target draws them, or with the heap compacting at every
reservation (or not at all, 1 in 6): every call of the second play must show what the
first one's did (lines, choice counts and errors, hashed per call), or a limit stops it
after the same calls. `save` plays to a drawn call (or the first after it with no fallback
choice pending in any flow, else to the step cap with no save), saves, loads the save into a fresh story, checks that it saves the same,
and plays both on with the same choices: the same calls, and the same save at the end.
`host` (P18.5) acts as a host on stories with `hub` and `typed` on (and without `drop` and
`collision`, so they compile): it puts an observer on every global and runs the simulator's
action mix (`simulation.simulate_mix` with `Mix.draw`: seeded choices, save and load, a flow
switch and back, `set_variable`, `evaluate_function`, `choose_path_string`, compact-always),
then a session of up to 48 host calls drawn as the host fuzz target draws them
(`fuzz/host.zig`: also `remove_flow`, tags, `get_variable`, visit counts, `reset_state`,
save and load); the state checks after every call, and a save loaded must save the same. It
leaves out the program checks, which play and save make, and binds `e0` unless its fallback
is allowed. `mutate` (P19.3, `src/testing/swarm_mutate.zig`) takes the ground-truth stories
instead of generated ones: their sources (`cases.ids`, found by `cases.source_path`; the two
with an INCLUDE left out) are read from disk once per run, from the repository root, and each
seed picks one and applies one to four seeded mutations: a line, a knot or stitch, or a
choice deleted, duplicated or swapped; `*` and `+` toggled; a number, a boolean, a divert
target or any word changed (to another word of the story, END, DONE or a name it doesn't
have); a piece of ink syntax put in; up to 32 bytes cut; or the rest cut off. A mutant that
doesn't compile counts its first error's code (the summary's codes line lists all of them); one
that compiles gets the program checks, then plays as `play` does on even seeds and as `save`
does on odd ones. Every declared external is bound when the plan binds `e0`. A mutant is at
most `source_bytes_max` long (a mutation that wouldn't fit is left out), the parser's gas and
the plays' step budget bound the rest. Every failure prints its configuration and the command
that reproduces it (a mutate failure names the story and the mutations; reproduced with
`--seeds 1`, it also prints the mutant's source); a
host failure's command also has `--mix <hex>` (`Mix.encode`), which replaces the drawn mix,
so a mix with an action's weight set to 0 shows whether the action matters. The run
ends with the **triage** (`src/testing/swarm_triage.zig`, after the swarm paper's §5): the
features on in every failing run are *triggers*, and those off in every failing run but
used by passing ones are *suppressors*. `--target save --seeds 2000` takes 39 s and finds
nothing.

### Regression seeds (P19.6)

A seed that once failed stays in `test/swarm_regressions.zon`, and `zig build ci` (through
`zig build test`) replays every entry: the swarm runner's test "the swarm regressions replay
on their stories without a failure" (`swarm_runner.replay`) runs the entry's target on its
story, `test/swarm_regressions/<target>-<seed>.ink`, with the plans, split, host plan and
mix the seed draws, and requires no failure. The story is kept rather than regenerated, so
a change to the generator or to the mutate corpus doesn't turn an entry into another case;
a change to how a seed draws its plans (`Plan.draw`, `Split.draw`, `HostPlan.draw`, the
simulator) still can, and the mix is kept for the host targets as `--mix` takes it. An
entry is `.{ .target = .host, .seed = 4051, .mix = 0x60901, .bug = "<commit>: <what it
found>" }`; `bug` must not be empty.

Every failure prints its entry (`regression: add .{ ... } to test/swarm_regressions.zon,
and the story the reproducing run writes to zig-out/swarm/regressions as
test/swarm_regressions/<target>-<seed>.ink`). The reproducing run (`--seeds 1`) writes the
story to `zig-out/swarm/regressions/` and prints the entry before it checks the seed, so a
seed that panics keeps them too. To add one: run the printed reproduce command, copy the
story to `test/swarm_regressions/`, add the entry with what it found, fix the bug, and check
that the entry fails with the fix reverted.

The list started with the swarm-found bugs of Phases 18 and 19. Each was found again by
reverting its fix on main (966566e) in a worktree and running the target in ReleaseSafe
from seed 1 for 60 s (3672 and 143492: on from the first panic for 150 s more, a run started
again after each panic), and each entry's replay fails with the fix reverted (Debug, the
test above with that entry alone):

| Entry | Fix | With the fix reverted |
|---|---|---|
| `host` 4051 | 92781ce, a limit error in the newline lookahead left a divert pending | `visit_changed_containers_due_to_divert` asserts in `choose_path_string` |
| `host` 3672 | cac1887, `evaluate_function` with more parameters than arguments | `complete_function_evaluation` asserts (reverted with 6395d85, whose `evaluation_floor` replaced it; passes with 6395d85 alone reverted) |
| `host` 69 | 6395d85, a nested `evaluate_function` popped below its frame | the evaluation stack asserts a step later |
| `mutate` 143492 | d986143, ill-formed UTF-8 went into the JSON as it was | `load of its JSON` |
| `mutate` 67029 | 38e57e6, a string in a thread's arguments inside an unclosed string | `expression_string` asserts (found by this search, a bug on main) |
| `save` 106 | 7fc407d, a loaded save put the current flow's record last | `save round trip` |
| `save` 19879 | 826f605, a loaded save saved visible places for choice indices | `save round trip` (seed 2977 of P19.9's notes no longer fails: the generator changed since) |

The long-string save (771ed57) was found by the save fuzz target and didn't fail in 60 s of
`--target save` with its fix reverted, so it has no entry; its unit test in `api_test.zig`
covers it. The replay takes about 0.3 s in Debug for the seven entries.

Each target's summary line also says what the runs reached, counted without allocating:
compile failures by the first error's diagnostic code (the most frequent four), played
stories that hit a runtime error, lines played, choices made, played stories still going
after the calls a play gets (`step cap`), and those that ended without an error before
it (`ended`); since P19.4 also the large configurations' runs (`large`), the stories also
compiled from files, their files and the broken ones (`included ... from ... files, ...
broken`), the plays that made more than 64 calls (`long plays`), and the flow switches and
removals (`flow changes`); since P18.3 also the stories stopped at their first line because `e0` had no
binding (`unbound externals`; a run with `e0` bound fails then), the second plays under
other limits (`limited runs`) and those a limit stopped (`limit errors`; for `save`, saves
too large for the loader's scratch), and the saves loaded mid-play and played on (`resumed
saves`); the host target's line also has the actions its mixes took, how the mixes ended
(`mixes`: `ended`, `stopped` by an error that failed `cont`, at the simulator's 300 lines in
a turn without a choice, `line_cap`, or at its 50 turns, `turn_cap`; since P19.7, and
counted under `ended` and `step cap` too), the host calls made after them, the changes the
observers saw (each compared with the global read back with `get_variable`, a difference
failing the seed, since P19.7), and the actions and calls that returned an error (by name,
the most frequent four). `--target host --seconds 3` from seed 1 after P19.7: 4,421 seeds,
mixes ended 2,027, stopped 0, line_cap 1,372, turn_cap 985 (a hub story that loops through
its knots without a choice is the line cap's), 180,441 observed changes, none differing. `--target all --seconds 9` from seed 1 (ReleaseSafe, Apple M-series), before
and after P18.1 made dropping names a swarm feature, after P18.2 added `hub` and
`typed`, after P18.3 bound `e0`, varied the limits and resumed saves, and after P18.4
folded the compile checks into play and save (and `all` dropped `compile`, so play and save
get 4.5 s each instead of 3 s), and after P18.5 added `host` (play 3.6 s, save and host 2.7 s
each), and after P18.6 added the `constructs` (5% fewer runs: the stories hold more):

| | compile failures | play: compiled | runtime errors | lines | choices | step cap |
| --- | --- | --- | --- | --- | --- | --- |
| before | 4,363 / 13,842 (31.5%) | 5,336 / 7,800 | 2,350 | 13,164 | 411 | 114 |
| after P18.1 | 1,413 / 12,278 (11.5%) | 6,255 / 7,085 | 2,991 | 16,887 | 442 | 154 |
| after P18.2 | 1,085 / 9,144 (11.9%) | 5,239 / 5,963 | 1,795 | 84,115 | 63,192 | 2,138 |
| after P18.3 | 1,065 / 8,968 (11.9%) | 4,177 / 4,749 | 883 | 81,110 | 58,993 | 2,018 |
| after P18.4 | 1,095 / 9,087 (12.0%) | 4,317 / 4,911 | 922 | 83,496 | 60,718 | 2,074 |
| after P18.5 | 818 / 6,834 (12.0%) | 3,686 / 4,188 | 775 | 72,202 | 52,738 | 1,803 |
| after P18.6 | 706 / 6,462 (10.9%) | 3,519 / 3,961 | 793 | 68,197 | 48,073 | 1,667 |

The failures left are the error features' (`name_conflict` is `collision`'s). Played
stories now run longer, so fewer fit in the time. After P18.3 a quarter of the runtime
errors left are the stories without a binding for `e0` (209 of 883); the play target plays
most seeds twice. Its throughput (`--target play --seconds 5`) went from 2,001 to 1,558
runs/s, `save` from 1,355 to 1,240 and `compile` stayed at about 3,000, so every seed gets
the second play (doing it on a fraction of the seeds would only pay below half the
throughput). P18.4's program checks (a second compile, the JSON and the image round trips)
cost `play` about 22% of its throughput (5,000 seeds from seed 99: 3.5 s before, 4.5 s
after; `--seconds 5` from seed 99: 1,390 to 1,530 runs/s before and 1,000 to 1,120 after, `save`
1,210 and 920, `compile` 2,930 and 2,280), under the 30% at which they would run on a fraction of
the seeds, so every compiled story gets them.

In that run the host target took 4,408 seeds, all compiling (they leave out `drop` and
`collision`): 124,245 lines, 76,627 choices, 16,035 mix actions (round_trip 3,933,
switch_flow 4,061, set_variable 4,478, evaluate 2,162, choose_path 1,401), 31,511 host
calls after them and 181,915 observed changes; 1,422 stories reported a runtime error, and
5,380 actions and calls returned one (ChoiceLimit 1,614, the session's out-of-range choice
index; VariableNotDeclared 1,252 and PathNotFound 1,087, its names outside the story's
pool; CannotRemoveDefaultFlow 605). `--target host --seconds 5` from seed 99 runs 1,624
seeds/s; 90 s from seed 100000 ran 145,346 seeds without a failure. Its first run found a
bug: a limit error in the newline lookahead restored the state but left the divert of the
failed function call pending (ink keeps it in the state, as `divertedPointer`), and
`choose_path_string` then asserted (`save_load_test.zig`, "a cont that fails in the newline
lookahead leaves no divert pending").

`-Dfuzz-swarm=off` makes every generated story use the full mix (`Swarm.all`) instead of a
drawn configuration, to measure swarm against it.

### Swarm against the full mix (2026-11-20)

Each target fuzzed from an empty corpus (`.zig-cache/f` and `.zig-cache/v` removed) for
`--fuzz=100K`, ReleaseSafe, Apple M3, once with drawn configurations and once with
`-Dfuzz-swarm=off`:

| Target | Swarm: coverage | Full mix: coverage | Swarm: unique runs | Full mix: unique runs | Default |
|---|---:|---:|---:|---:|---|
| Parser | 2,123 / 11,120 | 1,959 (−7.7%) | 4,472 | 4,021 | swarm |
| Sema and resolve | 3,175 / 13,315 | 3,002 (−5.4%) | 4,935 | 4,972 | swarm |
| Lower and emit | 6,225 / 18,831 | 6,002 (−3.6%) | 4,948 | 3,532 | swarm |
| VM | 7,583 / 21,316 | 7,246 (−4.4%) | 5,381 | 5,108 | swarm |
| Save and load | 8,684 / 23,302 | 8,429 (−2.9%) | 7,182 | 6,663 | swarm |
| Host API | 8,726 / 23,037 | 8,482 (−2.8%) | 6,445 | 4,938 | swarm |

Swarm reaches more coverage on every target at the same budget, so it stays the default
everywhere. (The full-mix host run stopped at 83,910 inputs; its inputs are slower.)

## Differential swarm run

The targets above check invariants: no crash, `check()` holds, round trips match. The
differential run also checks **behaviour**: each generated story is compiled and played by
inkz and by ink v1.2.1, and everything the host can observe must match. It is an offline
run, because ink needs .NET; `zig build` itself never does (plan D19).

```sh
zig build swarm-gen -Doptimize=ReleaseSafe -- --seed 1 --count 2000 --out zig-out/swarm/1
mise run reference:swarm -- zig-out/swarm/1
zig build swarm-check -Doptimize=ReleaseSafe -- zig-out/swarm/1
```

1. `swarm-gen` writes, for each case `<n>`:
   - `<n>.ink`: a generated story with its own drawn swarm configuration;
   - `<n>.actions`: `lines_max 1000`, `play_seeded <seed>`, `globals`, `save`, `load_fresh`
     and `globals`;
   - `<n>.swarm`: the configuration line and the seed.
   The same seed writes the same files.
2. `reference:swarm` runs `ink_harness batch <dir>` (`tools/ink_harness/Program.cs`), one
   .NET process for the whole directory. For each story it writes:
   - `<n>.ink.json` and `<n>.expected`, or
   - `<n>.compile_errors` when inklecate rejects the story, or
   - `<n>.timeout` when ink doesn't finish it in 5 s (a divert loop without output, or
     recursion without end).
   A thread that runs on can't be stopped, so after two timeouts the process exits with 3,
   and the script starts a new one, which skips the stories that have results.
   `lines_max` caps each `continue_maximally` in both harnesses alike: generated stories
   often loop with output.
3. `swarm-check` (`src/testing/differential.zig`) compiles each story with inkz and compares:
   - **compile acceptance**: both compile, or both reject;
   - **runtime**: inklecate's JSON played by inkz against ink's transcript (the oracle's
     comparison, so `save:` lines compare as JSON);
   - **pipeline**: inkz's own JSON played by inkz against ink's transcript;
   - **structure**: inkz's JSON against inklecate's.
   Each replay runs in its own process (`dev replay --json`), so a crash is a result. Every
   divergence is printed with its configuration, and the step fails.
4. `zig build swarm-reduce -- <dir> <n> --harness reference/ink_harness_build/ink_harness.dll`
   reduces a divergent case by features. It regenerates the case from its seed with one
   swarm feature removed at a time (a set key, or a bound lowered to its least value), runs
   ink on the candidate, and keeps the removal when the same kind of divergence stays. That
   is one ink run per feature, so a configuration of 60 features takes 61 runs.
5. A reduced divergence is either fixed, with a ground-truth case under
   `test/ground_truth/swarm/` (`mise run reference:expected -- swarm/<name>`), or, when
   inkz differs on purpose, one of the skips below.

### Nightly run

`.github/workflows/differential.yml` runs these three steps every night (and on demand,
`workflow_dispatch`, with an optional seed and count) on ubuntu-latest: it installs Zig
(`EuroZig/setup-zig`) and .NET 8, builds the harness (`reference.sh setup`), generates 1,000
cases with the run id as seed, and prints the `swarm-gen` command that writes them again. A
divergence fails the job; `tools/ink_harness/collect_divergences.sh` then copies each
divergent case's files, `check.log` and the harness's `batch.log` to the artifact
`divergences-<seed>`, with a `swarm-reduce` of the first three (10 minutes each at most).
200 cases took about a minute locally (ink's 5 s timeouts most of it), so 1,000 take about
5 minutes; the job's limit of 45 minutes leaves room for the reductions.

`swarm-check` doesn't count two kinds of difference as divergences, but only when the
transcripts match up to the line where they start:
- **ink exceptions**: ink throws a .NET exception that isn't one of ink's, such as
  `DivideByZeroException` for an integer `/` or `%` by 0. The host would crash; inkz reports
  ink's story error instead.
- **inkz limits**: inkz stops at one of its limits (`ThreadLimit`, `FrameLimit`...), which
  ink doesn't have, for example a knot that starts a thread of itself, or a save doesn't
  fit them to load (`SaveTooLarge`, a string that doubles each turn).

### Results (2026-11-20)

`--seed 1 --count 2000`: ink took 6.5 minutes and the check a few seconds.

| Outcome | Stories |
|---|---:|
| played by both | 1,309 |
| rejected by both | 601 |
| ink didn't finish in 5 s | 88 |
| ink crashed the process (a stack overflow) | 2 |
| ink exception (not compared after it) | 12 |
| inkz limit (not compared after it) | 10 |
| divergences, before the fixes below | 38 (12 compile acceptance, 26 runtime) |
| divergences, after them | 0 (the last 2 fixed in P16.21) |

The phase's acceptance run, `--seed 16 --count 10000` (ink took about 45 minutes), after
every fix of Phase 16:

| Outcome | Stories |
|---|---:|
| played by both or rejected by both, and compared | 9,561 |
| ink didn't finish in 5 s | 355 |
| ink crashed the process | 4 |
| ink exception (not compared after it) | 29 |
| inkz limit (not compared after it) | 51 |
| divergences | 0 |

It found two more differences, both fixed: a divert through a variable holding a number
says "it contained '1'." in ink (`swarm/divert_variable_holds_number`), and a story whose
text grows without end hits inkz's heap limit before ink runs out of memory, which the
checker now counts as an inkz limit.

`swarm-reduce` on one of the two, case 01848, took 34 ink runs (28 s). A removal that keeps the
divergence is kept, so the reduction stops short when a removal changes the story so much
that the divergence goes, as it did for the 46 extra globals there.

### What the differential run found

| Divergence | Fix | Ground truth |
|---|---|---|
| After `-> END`, a save had `"threadCounter":0`. ink's `ForceEnd` calls `CallStack.Reset`, which keeps the counter that every generated choice advances. | `CallStack.reset` keeps the counter; `CallStack.fresh` (a new flow, `reset_state`, a loaded save) starts it from 0. | `swarm/thread_counter_after_end` |
| A `->->` outside a tunnel gave inkz's own message. | ink's "Found tunnel onwards statement (->->), when expected end of flow (-> END or choice)". | `swarm/pop_unexpected` |
| An operation a type lacks, such as `?` on numbers, gave inkz's own message. | ink's "Cannot perform operation '?' on Float", with the type ink coerces the operands to. | `swarm/operation_not_for_type`, `swarm/operation_not_for_int` |
| inkz compiled `not v ? 1`, which ink rejects: "Using 'not' or '!' here negates 'v' rather than the result of the '?' or 'has' operator" (11 stories). | The check from `BinaryExpression.ResolveReferences`, code `negated_has_operand`. | unit test in `src/compiler/termination_tests.zig` |
| After two threads in a row that print nothing, ink saves the first thread's divert as `previousContentObject`, inkz the second's (2 stories). ink's live pointer is the second divert, but `Object.path` finds an object's index with `content.IndexOf`, which uses `Equals`, and two diverts with the same target are equal. | A save writes the index of the first equal divert in the container (P16.21; found by tracing ink's `Step` through reflection). | `swarm/thread_previous_pointer` |

## Coverage of the swarm

```sh
zig build swarm-coverage                    # --target all --seconds 60, then the report
zig build swarm-coverage -- --seconds 10    # later swarm arguments override
```

The step builds `dev` in ReleaseSafe with Zig's fuzz instrumentation (`-ffuzz`), which gives
every basic block a hit counter and records its address. After the run,
`src/testing/coverage.zig` resolves each block to its source line with the program's own
debug info (`std.debug.SelfInfo`), so it needs no kcov or llvm-cov and runs on macOS as on
Linux. It writes `zig-out/coverage/swarm.txt`: blocks and lines hit per module and per file,
then every run of lines none of whose blocks ran, as `file:first-last blocks`. A "line" is
a line on which some block starts; a line counts as hit when one of its blocks ran. Block
percentages are low because every safety check (overflow, bounds, `try`'s error edge) is a
block of its own that never runs, so read the line column. The coverage build also
references every public non-generic function of the library, so functions the swarm never
calls are compiled and listed instead of missing. Debug gives the same blocks but runs a
tenth of the seeds.

### Results (2026-11-23)

`zig build swarm-coverage` (60 s from seed 1: 10,437 play, 5,929 save and 11,920 host runs):

| Module | Lines | Hit | Lines % | Blocks % |
|---|---|---|---|---|
| src/compiler | 2,520 | 1,748 | 69.4 | 61.0 |
| src/runtime | 1,853 | 1,518 | 81.9 | 58.2 |
| src/core | 858 | 641 | 74.7 | 59.5 |

The swarm saturates in seconds: a 5-s run reaches 68.9, 80.6 and 74.8 %. More time adds
almost nothing; only new features do. The counts vary by a few lines between runs, as the
deadline decides the last seed.

Unreached **by design** (most of the listed ranges, nothing to do):

- **Error edges of `try`**: one-line ranges of one to three blocks, all over (allocation
  failure, a full writer). `src/core/allocation_failures.zig` and the zero-allocation gate
  test them, not the swarm.
- **Rejection of malformed input**: `src/core/ink_json.zig` (`expect`, `InvalidInkJson`),
  `src/core/program_image.zig:251,361-365,404-423` (truncated or inconsistent images),
  `src/runtime/load.zig` (`as`/`member` errors, `SaveDoesNotMatchStory` at 566),
  `src/core/string_pool.zig:113`. The swarm only feeds them what inkz wrote; the `json`,
  `image` and `save` fuzz targets mutate their input.
- **Invariant checks that fail only on a bug**: the `check`/`verify` failure returns in
  `bounded_stack.zig:89`, `call_stack.zig:349-365`, `program.zig:318-457`,
  `output.zig:402-413`, `lookahead.zig:211-219`, `text_cache.zig:120`, `choices.zig:235`,
  `limits.zig:304-315`.
- **Capacity limits**: `state.zig:421` (diagnostic list full), `evaluate.zig:227` (output
  stashes), `compiler/core.zig:290-359` (parser gas, frame stack, diagnostics).
- **Test and tool code**: `state.zig:511-615` (`State.hash`, for the fuzz targets),
  `core/counting_allocator.zig` (benchmarks), `program_builder.zig:749` (a debug log).

### Mutants of the ground-truth stories (P19.3, 2026-11-23)

`zig build swarm-coverage -- --seconds 20` from seed 1, before and after `all` got `mutate`
(2 of its 12 shares), and `--target mutate --seconds 20` alone, lines hit:

| Module | `all` before | `all` after | `mutate` alone |
|---|---|---|---|
| src/compiler | 1,750 (69.4 %) | 1,892 (75.1 %) | 1,903 (75.5 %) |
| src/runtime | 1,507 (81.3 %) | 1,536 (82.9 %) | 1,360 (73.4 %) |
| src/core | 643 (74.9 %) | 642 (74.8 %) | 636 (74.1 %) |

By file (blocks), `all` before and after: `grammar_statements.zig` 62.0 to 79.6 %,
`grammar_content.zig` 67.9 to 80.8 %, `messages.zig` 36.2 to 45.4 %, `lower_termination.zig`
69.1 to 80.9 %, `resolve_lookups.zig` 65.8 to 73.9 %. The error recovery the generator
never reached (`grammar_statements.zig:219-234,515-517`, `grammar_content.zig:458-462`,
`resolve_lookups.zig:93-103`, most of `lower_termination.zig:183-193`) runs now. Mutate's
share costs the other targets a sixth of their seeds and adds 5.7 points of compiler lines;
it saturates as fast as they do (3.3 s of a 20-s `all` reach 75.1 %, 20 s alone 75.5 %), so 2
shares are enough, and its runtime lines (the ground-truth stories play constructs the
generator doesn't write) add 1.6 points. In 20 s alone it ran 33,665 mutants: 20,189
compiled (60 %), 58,627 lines and 10,885 choices played, 18,119 plays ended and 226 reached
the step cap; the failures fell under 67 codes (`target_not_found` 3,480, `duplicate_flow`
1,370, `end_of_line` 1,322, `inner_logic` 994, ...). Its first runs found two bugs: the
mutator itself unwrapped a missing word in a story with only diverts, and the compiler took
ill-formed UTF-8 (a `’` cut in half) into its JSON as it was, which `ink_json.load` rejected;
it now replaces each maximal subpart with U+FFFD, as .NET's `File.ReadAllText` does for
inklecate (`compile.zig`, "ill-formed UTF-8 compiles as U+FFFD"). 200,000 seeds from seed
1,000,000 and 120 s from seed 5,000,000 (262,184 mutants) found nothing more.

Still unreached in `messages.zig`: the scope list (`scope_text`, 409-423) and the expression
printer (421-489, 549-613), and the texts of codes only a semantic error in an otherwise
valid story reaches (an increment of an unknown variable, a divert-target or `ref`
argument that isn't one, `not` before `?` or `has`, 746-1113). A mutation rarely makes
exactly those; a targeted generator feature would.

### Flows, INCLUDE, larger stories and step caps (P19.4, 2026-11-23)

`zig build swarm-coverage -- --target all --seconds 20` from seed 1, before and after
P19.4, lines hit:

| Module | before | after |
|---|---|---|
| src/compiler | 1,900 / 2,528 (75.2 %) | 2,004 / 2,534 (79.1 %) |
| src/runtime | 1,535 / 1,853 (82.8 %) | 1,539 / 1,863 (82.6 %) |
| src/core | 639 / 858 (74.5 %) | 642 / 858 (74.8 %) |

By file (blocks): `source_space.zig` 9.0 to 66.0 %, `sema_includes.zig` 0 to 73.1 %,
`compile.zig` 37.5 to 50.0 %, `messages.zig` 44.8 to 47.9 % (the INCLUDE problems),
`flows.zig` 76.9 to 80.0 %. Of the INCLUDE code only `try` error edges, a root in a
subdirectory (the path join, `source_space.zig:292-294`) and the depth and file-count
limits (304, 307) stay unreached; the `source_space.zig` tests cover them. The runtime
gains little: the host target switched and removed flows already. The seeds do more, so
fewer fit: 1,869 play, 1,377 save, 2,775 host and 5,602 mutate runs in the 20 s, against
2,675, 1,896, 3,115 and 5,567 before; 5,000 seeds take 7.5 s instead of 5.7 s for `play`
and 8.5 s instead of 6.5 s for `save` (ReleaseSafe; the step caps are 1.5 times as long on average, and a
quarter of the stories compile and play twice more). `--target all --seconds 60` from seed
1 then ran 13,982 play, 9,471 save, 19,028 host and 20,598 mutate seeds without a failure
(play: 753 large, 3,441 included from 8,602 files of which 414 broken, 2,198 long plays,
18,928 flow changes).

The flow changes found two bugs, both in the order of the flows in a save. A loaded save
gave the current flow the last record, so a save with `one` (current) and `two` saved back
as `two`, `one`; it now takes the records in the save's order first, as ink's dictionary
does (`save_load_test.zig`, "a loaded save keeps its flows in the save's order"). And a new
flow took the first free record, where .NET's Dictionary takes the one freed last (checked
with .NET 8); it now does the same (`flows.zig`, "a new flow takes the record freed last").
Two differences are ink's own and the save target allows them: after a flow is removed and
another made, a story and its loaded save list their flows in other orders (the loaded
dictionary has no holes), so the end saves compare but for flow order. A parked flow that
kept a fallback choice to the step cap had no save at first, as the loaded save saved other
choice indices: inkz recomputed them where ink keeps the saved ones, and it numbered a
fallback choice among the visible ones where ink leaves it 0. Both are fixed and the save is
made again (P19.9, ground-truth case `save_choice_indices`). Compiling from files found no difference to inklecate: the choice body's
newline above is inklecate's JSON too.

Real **gaps**, each assigned to a Phase 19 issue (P19.8 is git issue ba7dd2c):

| Area | Where | Follow-up |
|---|---|---|
| INCLUDE and `compile_file` | `compiler/source_space.zig:61-328`, `compiler/sema_includes.zig:19-108`, `compiler/compile.zig:176-226`, `grammar_statements.zig:376-381` | P19.4: done but a root in a subdirectory and the depth and file limits (below) |
| Most diagnostics: the generator only makes `drop` and `collision` errors | `compiler/messages.zig:190-267,409-613,746-1113` (texts of other codes, scopes, expressions), `grammar_statements.zig:219-234,515-517`, `grammar_content.zig:458-462,493-501` (error recovery), `lower_termination.zig:183-193`, `resolve_lookups.zig:93-103` | P19.3 (mutants): all but the scopes, the expression printer and the semantic-error texts (above) |
| `TURNS_SINCE`/`READ_COUNT` of `-> target`, divert targets in expressions | `runtime/vm.zig:500,516-529`, `resolve_passes.zig:290-323` | P19.8 |
| List `^`, `LIST_RANGE` with list bounds, a bare list item as a value | `runtime/lists.zig:223-230,357-362`, `runtime/ops.zig:520-523` | P19.8 |
| Comments, non-ASCII identifiers and text, `TODO:`, explicit list item values | `compiler/lexical.zig:16-22,60-69`, `grammar_statements.zig:360-365,465-471` | P19.8 |
| Floats printed in scientific notation | `runtime/value.zig:160-166` | P19.8 |
| Host API never called by the host target: `global_tags`, errors without a handler (`error_count`, `write_error`), `cont_alloc`, `unbind_external_function`, `init_from_json`, the `events` callbacks, a non-lookahead-safe external inside string evaluation | `runtime/story.zig:277-283,377-381,426-443,518,793,887-917`, `evaluate.zig:49,68-79`, `story_paths.zig:49`, `ops.zig:1013-1025` | P19.8 |
| A divert through a variable that holds no target | `runtime/vm.zig:399-407` | P19.8 |

## Results (2026-11-13)

All runs used ReleaseSafe unless noted. None crashed once the bugs below were fixed.

| Target | Runs | Unique | Coverage |
|---|---:|---:|---:|
| Comment removal (Debug) | 200,103 | 100 | 72 / 9,127 |
| INCLUDE discovery (Debug) | 244,495 | 264 | 1,574 / 11,331 |
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
| JSON loader | A content object with an empty key (`{"":"$r"}`) reached an assert. | `error.InvalidInkJson`; the cases are in "malformed input returns an error instead of crashing". |
| Save and load | A limit or host error in the newline lookahead left the snapshot active, and saving then asserted. | The story goes back to its last line (`Story.fail_step`). |
| Host API | After a limit error in the middle of a step, the next `cont` ran on from the half-done state and asserted in `end_string`. | The story fails closed with `error.StoryFailed` until `reset_state` or `load_json` (see `docs/RunningYourInk.md`). |
| Save and load (CI bounds, P19.5) | A global string that doubled past 64 KiB in play saved, but its save didn't load: `load_json` refused every string longer than a u16 with `error.SaveTooLarge`. | Only an output item's text, whose length is a u16, keeps the bound; a value's string is bounded by the heap ("a string variable longer than 64 KiB saves and loads" in `api_test.zig`). |
| Swarm `mutate` | A source with ill-formed UTF-8 compiled to JSON with the bytes as they were, which `ink_json.load` rejected. | Each maximal subpart compiles as U+FFFD, as inklecate reads it (`source_space.Decoded`). |

Two of the first assumptions turned out wrong; the parser was correct both times:

- Marker nodes (`newline`, `tag_end`, `empty_divert`) hold a source offset, not a token.
- Token starts aren't in order, because a peek rewinds the input but keeps its tokens.

One difference is ink's own behaviour, and inkz keeps it. ink's save doesn't keep a
choice's `isInvisibleDefault` (`JObjectToChoice` in `JsonSerialisation.cs`), so a pending
fallback choice becomes visible after a load, in C# ink and here. The save target therefore
doesn't compare such saves.
