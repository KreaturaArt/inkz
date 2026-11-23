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

`zig build swarm -Doptimize=ReleaseSafe -- --target <compile|play|save|host|all> --seed S --seeds N`
(or `--seconds T` instead of `--seeds`: as many seeds as fit; `all` is `play`, `save` and
`host`, with 4, 3 and 3 tenths of the time. CI runs `--target all --seconds 300` after `zig build ci` passes, and the
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
choice pending), saves, loads the save into a fresh story, checks that it saves the same,
and plays both on with the same choices: the same calls, and the same save at the end.
`host` (P18.5) acts as a host on stories with `hub` and `typed` on (and without `drop` and
`collision`, so they compile): it puts an observer on every global and runs the simulator's
action mix (`simulation.simulate_mix` with `Mix.draw`: seeded choices, save and load, a flow
switch and back, `set_variable`, `evaluate_function`, `choose_path_string`, compact-always),
then a session of up to 48 host calls drawn as the host fuzz target draws them
(`fuzz/host.zig`: also `remove_flow`, tags, `get_variable`, visit counts, `reset_state`,
save and load); the state checks after every call, and a save loaded must save the same. It
leaves out the program checks, which play and save make, and binds `e0` unless its fallback
is allowed. Every failure prints its configuration and the command that reproduces it; a
host failure's command also has `--mix <hex>` (`Mix.encode`), which replaces the drawn mix,
so a mix with an action's weight set to 0 shows whether the action matters. The run
ends with the **triage** (`src/testing/swarm_triage.zig`, after the swarm paper's §5): the
features on in every failing run are *triggers*, and those off in every failing run but
used by passing ones are *suppressors*. `--target save --seeds 2000` takes 39 s and finds
nothing.

Each target's summary line also says what the runs reached, counted without allocating:
compile failures by the first error's diagnostic code (the most frequent four), played
stories that hit a runtime error, lines played, choices made, played stories still going
after the 64 calls a play gets (`step cap`), and those that ended without an error before
it (`ended`); since P18.3 also the stories stopped at their first line because `e0` had no
binding (`unbound externals`; a run with `e0` bound fails then), the second plays under
other limits (`limited runs`) and those a limit stopped (`limit errors`; for `save`, saves
too large for the loader's scratch), and the saves loaded mid-play and played on (`resumed
saves`); the host target's line also has the actions its mixes took, the host calls made
after them, the changes the observers saw, and the actions and calls that returned an error
(by name, the most frequent four). `--target all --seconds 9` from seed 1 (ReleaseSafe, Apple M-series), before
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

Two of the first assumptions turned out wrong; the parser was correct both times:

- Marker nodes (`newline`, `tag_end`, `empty_divert`) hold a source offset, not a token.
- Token starts aren't in order, because a peek rewinds the input but keeps its tokens.

One difference is ink's own behaviour, and inkz keeps it. ink's save doesn't keep a
choice's `isInvisibleDefault` (`JObjectToChoice` in `JsonSerialisation.cs`), so a pending
fallback choice becomes visible after a load, in C# ink and here. The save target therefore
doesn't compare such saves.
