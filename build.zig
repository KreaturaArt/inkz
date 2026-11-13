const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Only run tests whose names contain this text (repeatable)",
    ) orelse &.{};
    const ledger_update = b.option(
        bool,
        "ledger-update",
        "Rewrite test/divergence_ledger.zon from the ground-truth comparison",
    ) orelse false;
    // Snapshot tests (tools/snapshot.zig) also read SNAP_UPDATE=1 when they run (reading
    // the environment here would defeat the configure cache).
    const snap_update = b.option(
        bool,
        "snap-update",
        "Rewrite snapshot files instead of checking them (or set SNAP_UPDATE=1)",
    ) orelse false;
    const build_options = b.addOptions();
    build_options.addOption(bool, "ledger_update", ledger_update);
    build_options.addOption(bool, "snap_update", snap_update);
    // The ground-truth gate replays each case in its own process (src/replay_case.zig).
    const replay_case = b.addExecutable(.{
        .name = "replay_case",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/replay_case.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    build_options.addOptionPath("replay_case_path", replay_case.getEmittedBin());
    // `zig build replay` installs it, for replaying one case by hand.
    const replay_step = b.step("replay", "Install replay_case (replay one case on an engine)");
    replay_step.dependOn(&b.addInstallArtifact(replay_case, .{}).step);

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
            .own_filters = &.{ "compiler.", "e2e_new_vm.", "e2e_new_vm_api.", "structure_gate.", "e2e_tests." },
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
    const profile_check = b.addExecutable(.{
        .name = "profile_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/profile_check.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_profile_check = b.addRunArtifact(profile_check);
    const test_profile = b.step("test-profile", "Check the profile zones with profiling on");
    test_profile.dependOn(&run_profile_check.step);
    test_all.dependOn(test_profile);
    test_all.dependOn(add_doctests(b, inkz_module, test_options));

    // Fuzz targets (P0.9): each runs on its seed corpus; `zig build fuzz --fuzz` fuzzes them.
    // Zig's fuzzer writes its log to <cache>/tmp and fails if that directory is missing.
    std.Io.Dir.cwd().createDirPath(b.graph.io, ".zig-cache/tmp") catch {};
    const fuzz_corpus = add_test_suite(b, .{
        .step = "fuzz",
        .root = "src/fuzz_targets.zig",
        .description = "Run fuzz targets on their corpus (add --fuzz to fuzz)",
        .own_filters = &.{"fuzz: "},
    }, test_options);

    const write_transcripts = b.addExecutable(.{
        .name = "write_transcripts",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/write_transcripts.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    write_transcripts.root_module.addOptions("build_options", build_options);
    const run_transcripts = b.addRunArtifact(write_transcripts);
    run_transcripts.setCwd(b.path("."));
    const transcripts_step = b.step("transcripts", "Regenerate test/transcripts");
    transcripts_step.dependOn(&run_transcripts.step);

    // Benchmarks in both release modes, one after the other (they write the same report).
    const bench_step = b.step("bench", "Run benchmarks in ReleaseSafe and ReleaseFast (P0.6)");
    var previous_bench: ?*std.Build.Step = null;
    for ([_]std.builtin.OptimizeMode{ .ReleaseSafe, .ReleaseFast }) |mode| {
        const bench = b.addExecutable(.{
            .name = b.fmt("bench_{t}", .{mode}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/bench.zig"),
                .target = target,
                .optimize = mode,
            }),
        });
        const run_bench = b.addRunArtifact(bench);
        run_bench.setCwd(b.path("."));
        if (previous_bench) |previous| run_bench.step.dependOn(previous);
        previous_bench = &run_bench.step;
        bench_step.dependOn(&run_bench.step);
    }

    // Program load and store, as ink's JSON and as the binary image, in both release modes;
    // results are appended to bench/load_store.jsonl.
    const bench_io_step = b.step("bench-io", "Benchmark JSON and binary image load/store");
    var previous_bench_io: ?*std.Build.Step = null;
    for ([_]std.builtin.OptimizeMode{ .ReleaseSafe, .ReleaseFast }) |mode| {
        const bench_io = b.addExecutable(.{
            .name = b.fmt("bench_io_{t}", .{mode}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/bench_io.zig"),
                .target = target,
                .optimize = mode,
            }),
        });
        const run_bench_io = b.addRunArtifact(bench_io);
        run_bench_io.setCwd(b.path("."));
        // Always run: each run is a new measurement.
        run_bench_io.has_side_effects = true;
        if (previous_bench_io) |previous| run_bench_io.step.dependOn(previous);
        previous_bench_io = &run_bench_io.step;
        bench_io_step.dependOn(&run_bench_io.step);
    }

    // Profile zones per pipeline stage (src/core/profile.zig), in ReleaseFast; results are
    // appended to bench/profile.jsonl.
    const bench_profile = b.addExecutable(.{
        .name = "bench_profile",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_profile.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    const run_bench_profile = b.addRunArtifact(bench_profile);
    run_bench_profile.setCwd(b.path("."));
    run_bench_profile.has_side_effects = true;
    const bench_profile_step = b.step("bench-profile", "Profile each pipeline stage");
    bench_profile_step.dependOn(&run_bench_profile.step);

    const simulate = b.addExecutable(.{
        .name = "simulate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/simulate.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    simulate.root_module.addOptions("build_options", build_options);
    const run_simulate = b.addRunArtifact(simulate);
    run_simulate.setCwd(b.path("."));
    run_simulate.addPassthruArgs();
    b.step("simulate", "Play every case with seeded random choices (P0.9)").dependOn(&run_simulate.step);

    const lint = b.addExecutable(.{
        .name = "lint",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/lint.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_lint = b.addRunArtifact(lint);
    run_lint.setCwd(b.path("."));
    run_lint.addArgs(&.{ "src", "tools" });
    b.step("lint", "Check TigerStyle rules (plan §3)").dependOn(&run_lint.step);

    const fmt = b.addFmt(.{
        .paths = &.{ b.path("build.zig"), b.path("build.zig.zon"), b.path("src"), b.path("tools") },
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

/// The docs whose ```zig blocks are compiled by `zig build doctest` (tools/doctest.zig).
const doctest_docs = [_][]const u8{
    "docs/RunningYourInk.md",
    "docs/ArchitectureAndDevOverview.md",
    "docs/Guidelines.md",
    "docs/Architecture.md",
};

/// `zig build doctest` (plan P9.3): extracts the docs' Zig samples into a generated test
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

/// `zig build test-death` (plan D20): runs each case in `src/death_cases.zig` as its own
/// child process and checks how it ends. Always built in Debug, so assertions are on.
fn add_death_tests(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step {
    const runner = b.addExecutable(.{
        .name = "death",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/death.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
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
    // Tests read files under test/ (fixtures, ground truth, the ledger) that the build cache
    // doesn't track, so they run every time.
    run.has_side_effects = true;
    b.step(suite.step, suite.description).dependOn(&run.step);
    return &run.step;
}
