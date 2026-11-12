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
    const build_options = b.addOptions();
    build_options.addOption(bool, "ledger_update", ledger_update);
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

    const lib = b.addLibrary(.{
        .name = "inkz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });
    b.installArtifact(lib);

    // `test` runs every suite once; each suite also has its own step.
    const test_all = b.step("test", "Run all unit tests");
    const suites = [_]TestSuite{
        .{ .step = "test-runtime", .root = "src/test_runtime.zig", .description = "Run runtime tests" },
        .{
            .step = "test-compiler",
            .root = "src/test_compiler.zig",
            .description = "Run compiler tests",
            .own_filters = &.{ "compiler.", "compiler_helpers." },
        },
        .{ .step = "test-core", .root = "src/core/root.zig", .description = "Run shared core tests" },
        .{
            .step = "test-vm",
            .root = "src/test_vm.zig",
            .description = "Run new runtime tests",
            .own_filters = &.{"vm."},
        },
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

    // Fuzz targets (P0.9): each runs on its seed corpus; `zig build fuzz --fuzz` fuzzes them.
    // Zig's fuzzer writes its log to <cache>/tmp and fails if that directory is missing.
    std.Io.Dir.cwd().createDirPath(b.graph.io, ".zig-cache/tmp") catch {};
    _ = add_test_suite(b, .{
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
    const transcripts_step = b.step("transcripts", "Regenerate test/transcripts (old runtime)");
    transcripts_step.dependOn(&run_transcripts.step);

    const heuristics = b.addExecutable(.{
        .name = "heuristics_report",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/heuristics_report.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    heuristics.root_module.addOptions("build_options", build_options);
    const run_heuristics = b.addRunArtifact(heuristics);
    run_heuristics.setCwd(b.path("."));
    const heuristics_step = b.step("heuristics-report", "Count weave-heuristic firings (P0.12)");
    heuristics_step.dependOn(&run_heuristics.step);

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

    const inventory = b.addExecutable(.{
        .name = "test_inventory",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/test_inventory.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_inventory = b.addRunArtifact(inventory);
    run_inventory.setCwd(b.path("."));
    const inventory_step = b.step("test-inventory", "Count old-runtime tests that use internals");
    inventory_step.dependOn(&run_inventory.step);
}

const death_cases = @import("src/core/death_cases.zig");

/// `zig build test-death` (plan D20): runs each case in `src/core/death_cases.zig` as its own
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
        .root_source_file = b.path("src/core/death_cases.zig"),
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
    const run = b.addRunArtifact(tests);
    // Tests read files under test/ (fixtures, ground truth, the ledger) that the build cache
    // doesn't track, so they run every time.
    run.has_side_effects = true;
    b.step(suite.step, suite.description).dependOn(&run.step);
    return &run.step;
}
