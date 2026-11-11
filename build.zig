const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Only run tests whose names contain this text (repeatable)",
    ) orelse &.{};

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
        .{ .step = "test-tools", .root = "tools/lint.zig", .description = "Run tests of the tools" },
    };
    const test_options: TestOptions = .{ .target = target, .optimize = optimize, .filters = test_filters };
    for (suites) |suite| {
        test_all.dependOn(add_test_suite(b, suite, test_options));
    }

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

    // Tool steps that fail with a pointer to their issue until the tool exists.
    const pending = [_]PendingTool{
        .{ .step = "bench", .description = "Run benchmarks", .issue = "TASK-140.6" },
        .{ .step = "fuzz", .description = "Run fuzz targets", .issue = "TASK-140.9" },
        .{ .step = "simulate", .description = "Run the story simulator", .issue = "TASK-140.9" },
    };
    for (pending) |tool| {
        const step = b.step(tool.step, tool.description);
        const message = b.fmt("'{s}' is not implemented yet ({s})", .{ tool.step, tool.issue });
        step.dependOn(&b.addFail(message).step);
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

const PendingTool = struct {
    step: []const u8,
    description: []const u8,
    issue: []const u8,
};

const TestOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    filters: []const []const u8,
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
    const run = b.addRunArtifact(tests);
    b.step(suite.step, suite.description).dependOn(&run.step);
    return &run.step;
}
