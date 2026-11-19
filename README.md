# inkz

A Zig rewrite of [ink](https://github.com/inkle/ink), inkle's scripting language for
interactive narrative: a runtime that plays compiled stories (`.ink.json` or its own binary
program image) and a compiler from `.ink` source, replacing inklecate.

The design is data-oriented: a story compiles to an immutable `Program` (struct-of-arrays,
`u32` index newtypes, compact instructions), and the runtime makes one allocation at
`Story.init` and none after it. Behaviour is checked against ink's C# implementation
(ground-truth transcripts in `test/`).

## Requirements

Zig 0.17.1 (pinned in `mise.toml`; `mise install` gets it). No other dependency is needed to
build or test; the .NET reference harness (`tools/ink_harness`) is only used to regenerate
ground truth.

## Build and test

```sh
zig build            # the static library (zig-out/lib)
zig build test       # every test suite, the death tests and the doc samples
zig build lint       # TigerStyle rules (TIGER_STYLE.md)
zig build fmt        # formatting check
zig build ci         # what CI runs: fmt, lint, test and the fuzz corpus
zig build --help     # every step: bench, bench-io, bench-profile, transcripts, simulate, ...
```

## Usage

Add inkz as a dependency and import the `inkz` module
(`b.dependency("inkz", .{}).module("inkz")`). The outline of a host:

```text
var program = try inkz.compiler.compile_source(gpa, source);  // or ink_json.load / program_image.load
var story: inkz.Story = undefined;
try story.init(gpa, &program, .{});
while (story.can_continue()) print((try story.cont()).get());
// current_choices_count / current_choice(i) / choose_choice_index(i), then continue again
```

`docs/RunningYourInk.md` has the full, compiled examples (variables, external functions,
saves, flows, errors). The stable API is listed in `src/root.zig`.

## Documentation

- [Running your ink](docs/RunningYourInk.md): the host API guide and the migration table
- [Architecture](docs/Architecture.md): diagrams of the pipeline, program image, compiler and VM
- [Architecture and development overview](docs/ArchitectureAndDevOverview.md): a tour of the
  source tree, build steps and ground truth
- [Benchmarks](docs/benchmarks.md): measurements and how to run them
- [Fuzzing](docs/fuzzing.md): the fuzz targets and how to run them
- [Guidelines](docs/Guidelines.md) and [TIGER_STYLE.md](TIGER_STYLE.md): engineering rules

## License

See [LICENSE](LICENSE).
