const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Only run tests whose names contain this text (repeatable)",
    ) orelse &.{};
    // Snapshot tests (tools/snapshot.zig) also read SNAP_UPDATE=1 when they run (reading
    // the environment here would defeat the configure cache).
    const snap_update = b.option(
        bool,
        "snap-update",
        "Rewrite snapshot files instead of checking them (or set SNAP_UPDATE=1)",
    ) orelse false;
    const bench_record = b.option(
        bool,
        "bench-record",
        "bench-io and bench-profile append to bench/*.jsonl (default: zig-out/bench/)",
    ) orelse false;
    const fuzz_swarm = b.option(
        bool,
        "fuzz-swarm",
        "Generated stories draw a swarm configuration (default); off uses the full mix, " ++
            "for measuring swarm against it",
    ) orelse true;
    // The dev tool (src/dev.zig): `zig build <command> -- <arguments>` runs one of its
    // commands. Its build options can't name its own binary; the tests' options do, because
    // the ground-truth gate replays each case in its own `dev replay` process.
    const dev = add_executable(b, "dev", "src/dev.zig", target, optimize);
    dev.root_module.addOptions("build_options", new_build_options(b, snap_update, fuzz_swarm));
    const build_options = new_build_options(b, snap_update, fuzz_swarm);
    build_options.addOptionPath("dev_path", dev.getEmittedBin());
    for (dev_commands) |command| {
        const run = b.addRunArtifact(dev);
        run.setCwd(b.path("."));
        run.has_side_effects = true;
        run.addArg(command[0]);
        run.addPassthruArgs();
        b.step(command[0], command[1]).dependOn(&run.step);
    }

    // The library's module, for packages that depend on inkz (`b.dependency("inkz", ...)
    // .module("inkz")`) and for the doctests.
    const inkz_module = b.addModule("inkz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lib = b.addLibrary(.{
        .name = "inkz",
        .root_module = inkz_module,
        .linkage = .static,
    });
    b.installArtifact(lib);

    // `test` runs every suite once; each suite also has its own step.
    const test_all = b.step("test", "Run all unit tests");
    const suites = [_]TestSuite{
        .{
            .step = "test-runtime",
            .root = "src/test_runtime.zig",
            .description = "Run runtime tests",
            .own_filters = &.{ "runtime.", "death_cases.", "testing." },
        },
        .{
            .step = "test-compiler",
            .root = "src/test_compiler.zig",
            .description = "Run compiler tests",
            .own_filters = &.{ "compiler.", "e2e_api.", "structure_gate.", "e2e_tests." },
        },
        .{ .step = "test-core", .root = "src/core/root.zig", .description = "Run shared core tests" },
        .{ .step = "test-tools", .root = "tools/tests.zig", .description = "Run tests of the tools" },
    };
    const test_options: TestOptions = .{
        .target = target,
        .optimize = optimize,
        .filters = test_filters,
        .build_options = build_options,
    };
    for (suites) |suite| {
        test_all.dependOn(add_test_suite(b, suite, test_options));
    }

    test_all.dependOn(add_death_tests(b, target));

    // The profile zones with profiling compiled in (a test's root can't enable them).
    const profile_check = "src/profile_check.zig";
    const run_profile_check = b.addRunArtifact(
        add_executable(b, "profile_check", profile_check, target, optimize),
    );
    const test_profile = b.step("test-profile", "Check the profile zones with profiling on");
    test_profile.dependOn(&run_profile_check.step);
    test_all.dependOn(test_profile);
    test_all.dependOn(add_doctests(b, inkz_module, test_options));

    // Fuzz targets: each runs on its seed corpus; `zig build fuzz --fuzz` fuzzes them.
    // Zig's fuzzer writes its log to <cache>/tmp and fails if that directory is missing.
    const fuzz_tmp = ".zig-cache/tmp";
    std.Io.Dir.cwd().createDirPath(b.graph.io, fuzz_tmp) catch |err| {
        std.process.fatal("cannot create {s} for the fuzzer: {t}", .{ fuzz_tmp, err });
    };
    const fuzz_corpus = add_test_suite(b, .{
        .step = "fuzz",
        .root = "src/fuzz_targets.zig",
        .description = "Run fuzz targets on their corpus (add --fuzz to fuzz)",
        .own_filters = &.{"fuzz: "},
    }, test_options);

    // Benchmarks (src/bench.zig, one program with a subcommand per kind). Each run is a new
    // measurement, so they always run. `bench` rewrites docs/benchmarks.md; `bench-io`
    // (program load and store) and `bench-profile` (profile zones per pipeline stage, in
    // ReleaseFast) append to zig-out/bench/*.jsonl, or with -Dbench-record to bench/*.jsonl.
    const bench_step = b.step("bench", "Run benchmarks in ReleaseSafe and ReleaseFast");
    add_release_benches(b, bench_step, target, &.{"runtime"});
    const bench_io_step = b.step("bench-io", "Benchmark JSON and binary image load/store");
    add_release_benches(b, bench_io_step, target, if (bench_record)
        &.{ "io", "--record" }
    else
        &.{"io"});
    const bench_profile_step = b.step("bench-profile", "Profile each pipeline stage");
    const bench_profile = add_bench(b, "bench_profile", "src/bench_profile.zig", target, .fast);
    bench_profile.addArg("profile");
    if (bench_record) bench_profile.addArg("--record");
    bench_profile_step.dependOn(&bench_profile.step);

    const lint = add_executable(b, "lint", "tools/lint.zig", target, optimize);
    const run_lint = b.addRunArtifact(lint);
    run_lint.setCwd(b.path("."));
    run_lint.addArgs(&.{ "src", "tools" });
    b.step("lint", "Check TigerStyle rules").dependOn(&run_lint.step);

    const code_size = add_executable(b, "code_size", "tools/code_size.zig", target, optimize);
    const run_code_size = b.addRunArtifact(code_size);
    run_code_size.setCwd(b.path("."));
    run_code_size.addArgs(&.{ "src", "tools", "build.zig" });
    run_code_size.has_side_effects = true;
    b.step("code-size", "Count lines of Zig per module").dependOn(&run_code_size.step);

    const fmt = b.addFmt(.{
        .paths = &.{
            b.path("build.zig"),
            b.path("build.zig.zon"),
            b.path("src"),
            b.path("tools"),
            b.path("test"),
        },
        .check = true,
    });
    b.step("fmt", "Check that the Zig sources are formatted").dependOn(&fmt.step);

    // `zig build ci` (.github/workflows/ci.yml): everything a change must pass. It needs no
    // reference harness (no dotnet, no reference/).
    const ci_step = b.step("ci", "Run formatting, lint, every test and the fuzz corpus");
    ci_step.dependOn(&fmt.step);
    ci_step.dependOn(&run_lint.step);
    ci_step.dependOn(test_all);
    ci_step.dependOn(fuzz_corpus);
}

/// `zig build <command>` runs `dev <command>` (src/dev.zig) with the arguments after `--`.
const dev_commands = [_][2][]const u8{
    .{ "replay", "Replay one case and print its transcript (-- <id> | --json PATH --actions A)" },
    .{ "simulate", "Play every case with seeded random choices" },
    .{ "transcripts", "Regenerate test/transcripts" },
    .{ "swarm", "Seeded swarm runs (-- --target compile|play|save --seed S --seeds N)" },
    .{ "swarm-gen", "Write generated swarm cases (-- --seed S --count N --out DIR)" },
    .{ "swarm-check", "Compare inkz with ink's results for swarm cases (-- DIR)" },
    .{ "swarm-reduce", "Reduce a divergent swarm case (-- DIR CASE --harness DLL)" },
};

fn new_build_options(b: *std.Build, snap_update: bool, fuzz_swarm: bool) *std.Build.Step.Options {
    const options = b.addOptions();
    options.addOption(bool, "snap_update", snap_update);
    options.addOption(bool, "fuzz_swarm", fuzz_swarm);
    return options;
}

fn add_executable(
    b: *std.Build,
    name: []const u8,
    root: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = optimize,
        }),
    });
}

/// A benchmark's run, in the project directory and every time.
fn add_bench(
    b: *std.Build,
    name: []const u8,
    root: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Run {
    const run = b.addRunArtifact(add_executable(b, name, root, target, optimize));
    run.setCwd(b.path("."));
    run.has_side_effects = true;
    return run;
}

/// Runs src/bench.zig with `arguments` in ReleaseSafe, then in ReleaseFast (never both at
/// once: they would measure each other, and they write the same files).
fn add_release_benches(
    b: *std.Build,
    step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    arguments: []const []const u8,
) void {
    var previous: ?*std.Build.Step = null;
    for ([_]std.builtin.OptimizeMode{ .safe, .fast }) |mode| {
        const run = add_bench(b, b.fmt("bench_{t}", .{mode}), "src/bench.zig", target, mode);
        run.addArgs(arguments);
        if (previous) |before| run.step.dependOn(before);
        previous = &run.step;
        step.dependOn(&run.step);
    }
}

/// The docs whose ```zig blocks are compiled by `zig build doctest` (tools/doctest.zig).
const doctest_docs = [_][]const u8{
    "docs/RunningYourInk.md",
    "docs/ArchitectureAndDevOverview.md",
    "docs/Guidelines.md",
    "docs/Architecture.md",
};

/// `zig build doctest`: extracts the docs' Zig samples into a generated test
/// root and compiles it against the library module.
fn add_doctests(
    b: *std.Build,
    inkz_module: *std.Build.Module,
    options: TestOptions,
) *std.Build.Step {
    const generator = b.addExecutable(.{
        .name = "doctest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/doctest.zig"),
            .target = b.graph.host,
        }),
    });
    const generate = b.addRunArtifact(generator);
    const directory = generate.addOutputDirectoryArg("doctest");
    for (doctest_docs) |doc| generate.addFileArg(b.path(doc));
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = directory.path(b, "root.zig"),
            .target = options.target,
            .optimize = options.optimize,
            .imports = &.{.{ .name = "inkz", .module = inkz_module }},
        }),
        .filters = options.filters,
    });
    const run = b.addRunArtifact(tests);
    const step = b.step("doctest", "Compile the Zig samples in docs/*.md against the library");
    step.dependOn(&run.step);
    return &run.step;
}

const death_cases = @import("src/death_cases.zig");

/// `zig build test-death`: runs each case in `src/death_cases.zig` as its own
/// child process and checks how it ends. Always built in Debug, so assertions are on.
fn add_death_tests(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step {
    const runner = add_executable(b, "death", "tools/death.zig", target, .debug);
    runner.root_module.addAnonymousImport("death_cases", .{
        .root_source_file = b.path("src/death_cases.zig"),
    });
    const step = b.step("test-death", "Run cases that must panic, one process each");
    const Expected = std.process.Child.Term;
    const aborted: Expected = .{ .signal = .ABRT };
    const caught: Expected = .{ .exited = death_cases.did_not_die_exit_code };
    const returned: Expected = .{ .exited = 0 };
    add_death_group(b, runner, step, death_cases.must_panic, aborted);
    add_death_group(b, runner, step, death_cases.self_test_must_panic, caught);
    add_death_group(b, runner, step, death_cases.must_return, returned);
    return step;
}

fn add_death_group(
    b: *std.Build,
    runner: *std.Build.Step.Compile,
    step: *std.Build.Step,
    comptime group: type,
    expected: std.process.Child.Term,
) void {
    inline for (comptime std.meta.declarations(group)) |declaration| {
        const run = b.addRunArtifact(runner);
        run.setName(b.fmt("death {s}", .{declaration}));
        run.addArg(declaration);
        run.addCheck(.{ .expect_term = expected });
        // Capturing stderr keeps the expected panic traces out of the build output, and makes
        // sure an abort really came from a panic.
        const stderr_match = if (expected == .signal) "panic: " else "";
        run.addCheck(.{ .expect_stderr_match = stderr_match });
        step.dependOn(&run.step);
    }
}

const TestSuite = struct {
    step: []const u8,
    root: []const u8,
    description: []const u8,
    /// Test-name prefixes that belong to this suite. The compiler imports the runtime, so
    /// without these the runtime's tests would also run in `test-compiler`.
    own_filters: []const []const u8 = &.{},
};

const TestOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    filters: []const []const u8,
    build_options: *std.Build.Step.Options,
};

fn add_test_suite(b: *std.Build, suite: TestSuite, options: TestOptions) *std.Build.Step {
    // A user filter narrows the suite; it doesn't widen it past the suite's own tests.
    const filters = if (options.filters.len > 0) options.filters else suite.own_filters;
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(suite.root),
            .target = options.target,
            .optimize = options.optimize,
        }),
        .filters = filters,
    });
    tests.root_module.addOptions("build_options", options.build_options);
    tests.root_module.addAnonymousImport("snapshot", .{ .root_source_file = b.path("tools/snapshot.zig") });
    const run = b.addRunArtifact(tests);
    // Tests read files under test/ (fixtures, ground truth, transcripts) that the build cache
    // doesn't track, so they run every time.
    run.has_side_effects = true;
    b.step(suite.step, suite.description).dependOn(&run.step);
    return &run.step;
}
