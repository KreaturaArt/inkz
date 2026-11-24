//! Reduces a failing swarm case of any target (`zig build swarm -- --reduce`, src/dev.zig)
//! with the reducer of `swarm-reduce` (`reduce.zig`): a seed's generated case first by
//! features (each candidate generated again from the seed with a feature less), then the
//! story, given or reduced, by lines; a candidate is kept while the seed fails on it with the
//! same reason (`swarm_runner.replay_case`). Each check runs here, or, `isolated`, in a child
//! process (`dev swarm --story`), so that a crash is a reason too: where it panicked.

const std = @import("std");
const assert = std.debug.assert;
const runner = @import("swarm_runner.zig");
const reduce = @import("reduce.zig");
const isolated = @import("isolated.zig");
const fuzz_ink = @import("fuzz_ink.zig");
const swarm_mutate = @import("swarm_mutate.zig");
const Swarm = fuzz_ink.Swarm;
const Case = fuzz_ink.Generator.Case;

pub const Request = struct {
    regression: runner.Regression,
    /// The story to reduce; null: the seed's case (generated, or the mutate target's mutant).
    story: ?[]const u8 = null,
    /// The mutate target's stories, for a seed without `story`.
    corpus: ?*const swarm_mutate.Corpus = null,
    /// Checks in child processes, writing each candidate to `candidate_path`.
    isolated: ?std.Io = null,
    candidate_path: []const u8 = "",
    /// Shared by the two stages: their calls together, and the deadline.
    bound: reduce.Bound,
};

pub const Result = struct {
    reason: []const u8,
    /// The reduced configuration of a generated case, else null.
    swarm: ?Swarm,
    features_before: u32 = 0,
    features_after: u32 = 0,
    lines_before: u32,
    lines_after: u32,
    source: []const u8,
    calls: u32,
    /// Whether the bound stopped it short.
    stopped: bool,

    pub fn format(result: Result, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("({s}) in {d} checks{s}, ", .{
            result.reason,
            result.calls,
            if (result.stopped) ", stopped by the bound" else "",
        });
        if (result.swarm) |swarm| {
            try writer.print("features {d} to {d} ({f}), ", .{
                result.features_before,
                result.features_after,
                swarm,
            });
        }
        try writer.print("lines {d} to {d}", .{ result.lines_before, result.lines_after });
    }
};

/// Null when the request's seed doesn't fail on its case. The result's texts are in `arena`.
pub fn run(gpa: std.mem.Allocator, arena: std.mem.Allocator, request: Request) !?Result {
    const regression = request.regression;
    const target = regression.target;
    assert(request.story == null or target != .synthetic);
    assert(request.isolated == null or target != .synthetic);
    const generated = request.story == null and target != .mutate;
    const buffer = try arena.alloc(u8, fuzz_ink.source_bytes_max);
    const start: Case = if (request.story) |story|
        .{ .source = story, .swarm = .none, .used = .none }
    else if (generated)
        runner.generate(target, regression.seed, null, buffer)
    else mutated: {
        const buffers = try arena.create(swarm_mutate.Buffers);
        const mutant = swarm_mutate.mutate(request.corpus.?, regression.seed, buffers);
        break :mutated .{ .source = mutant.source, .swarm = .none, .used = .none };
    };
    var checker: Checker = .{
        .gpa = gpa,
        .arena = arena,
        .request = request,
        .reason = undefined,
    };
    checker.reason = try checker.failure(start) orelse return null;
    var result: Result = .{
        .reason = checker.reason,
        .swarm = null,
        .lines_before = count_lines(start.source),
        .lines_after = 0,
        .source = start.source,
        .calls = 1,
        .stopped = false,
    };
    var swarm = start.swarm;
    if (generated) {
        var features: FeatureOracle = .{ .checker = &checker, .buffer = buffer };
        const reduction = try reduce.features(start.swarm, &features, request.bound);
        swarm = reduction.swarm;
        result.swarm = swarm;
        result.features_before = reduce.features_count(start.swarm);
        result.features_after = reduce.features_count(swarm);
        result.calls = reduction.calls;
        result.stopped = reduction.stopped;
        const reduced = runner.generate(target, regression.seed, swarm, buffer);
        result.source = try arena.dupe(u8, reduced.source);
    }
    var bound = request.bound;
    bound.calls_max -|= result.calls;
    if (bound.calls_max > 0 and !result.stopped) {
        var lines: LineOracle = .{ .checker = &checker, .swarm = swarm };
        const out = try arena.alloc(u8, result.source.len);
        const reduction = reduce.lines(gpa, result.source, out, &lines, bound) catch |err| {
            // A generated case reduced by features fails the same: the line stage confirms it.
            assert(err != error.NoFailure);
            return err;
        };
        result.source = reduction.source;
        result.calls += reduction.calls;
        result.stopped = reduction.stopped;
    }
    result.lines_after = count_lines(result.source);
    return result;
}

fn count_lines(source: []const u8) u32 {
    var count: u32 = @intCast(std.mem.count(u8, source, "\n"));
    if (source.len > 0 and source[source.len - 1] != '\n') count += 1;
    return count;
}

const Checker = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    request: Request,
    /// What the case failed with.
    reason: []const u8,

    /// What the seed fails with on `case`, or null.
    fn failure(checker: *const Checker, case: Case) !?[]const u8 {
        const io = checker.request.isolated orelse {
            return runner.replay_case(checker.gpa, checker.request.regression, case);
        };
        return check_isolated(checker.arena, io, checker.request, case.source);
    }

    fn same(checker: *const Checker, case: Case) !bool {
        const reason = try checker.failure(case) orelse return false;
        return std.mem.eql(u8, reason, checker.reason);
    }
};

/// The feature stage's oracle: the seed's case generated with the candidate.
const FeatureOracle = struct {
    checker: *const Checker,
    buffer: []u8,

    pub fn keeps(oracle: *FeatureOracle, candidate: Swarm) !bool {
        const regression = oracle.checker.request.regression;
        const case = runner.generate(regression.target, regression.seed, candidate, oracle.buffer);
        return oracle.checker.same(case);
    }
};

/// The line stage's oracle: the candidate story, with the case's configuration (the
/// synthetic target's failure).
const LineOracle = struct {
    checker: *const Checker,
    swarm: Swarm,

    pub fn keeps(oracle: *LineOracle, text: []const u8) !bool {
        return oracle.checker.same(.{ .source = text, .swarm = oracle.swarm, .used = .none });
    }
};

/// Writes `source` to the request's candidate path and replays it in `dev swarm --story`:
/// the reason it prints, or, when it crashed, where (`crash_reason`).
fn check_isolated(
    arena: std.mem.Allocator,
    io: std.Io,
    request: Request,
    source: []const u8,
) !?[]const u8 {
    assert(request.candidate_path.len > 0);
    const regression = request.regression;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = request.candidate_path, .data = source });
    var arguments: std.ArrayList([]const u8) = .empty;
    try arguments.appendSlice(arena, &.{
        "--target",
        @tagName(regression.target),
        "--seed",
        try std.fmt.allocPrint(arena, "{d}", .{regression.seed}),
        "--story",
        request.candidate_path,
    });
    if (regression.mix) |mix| {
        const text = try std.fmt.allocPrint(arena, "{x}", .{mix});
        try arguments.appendSlice(arena, &.{ "--mix", text });
    }
    const result = try isolated.run_dev(arena, io, "swarm", arguments.items);
    if (result.term == .exited and result.term.exited <= 1) return replay_reason(result.stdout);
    return try crash_reason(arena, result.stderr, result.term);
}

/// The reason in `dev swarm --story`'s output, `replay: failure (<reason>)`, or null for
/// `replay: pass`.
fn replay_reason(stdout: []const u8) error{UnexpectedReplayOutput}!?[]const u8 {
    const failure = "replay: failure (";
    if (std.mem.indexOf(u8, stdout, failure)) |at| {
        const rest = stdout[at + failure.len ..];
        const end = std.mem.indexOf(u8, rest, ")\n") orelse return error.UnexpectedReplayOutput;
        return rest[0..end];
    }
    if (std.mem.indexOf(u8, stdout, "replay: pass\n") != null) return null;
    return error.UnexpectedReplayOutput;
}

/// `<panic message> in <function>, at <frame>`: the panic's message, the function of its
/// trace's first frame (an assert's, inlined there in ReleaseSafe) and the first frame
/// outside the standard library, from `src/` on; or the way it ended, without a trace.
fn crash_reason(
    arena: std.mem.Allocator,
    stderr: []const u8,
    term: std.process.Child.Term,
) ![]const u8 {
    var message: []const u8 = "crash";
    var function: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, " panic: ")) |at| {
            message = line[at + " panic: ".len ..];
            continue;
        }
        const address = std.mem.indexOf(u8, line, ": 0x") orelse continue;
        const name = std.mem.indexOfPos(u8, line, address, " in ") orelse continue;
        if (function == null) function = line[name + " in ".len ..];
        if (std.mem.indexOf(u8, line, "/std/") != null) continue;
        const from = std.mem.indexOf(u8, line, "src/") orelse continue;
        return std.fmt.allocPrint(arena, "{s} in {s}, at {s}{s}", .{
            message,
            function.?,
            line[from..address],
            line[name..],
        });
    }
    return std.fmt.allocPrint(arena, "{s}: {any}", .{ message, term });
}

// Tests.

test "a synthetic failure of a generated case reduces by features and lines" {
    // P19.7: the synthetic target fails on glue without RANDOM, whatever the story: the
    // feature stage keeps glue and nothing it doesn't need, and the line stage leaves no
    // line, since the source plays no part.
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var seed: u64 = 1;
    var buffer: [fuzz_ink.source_bytes_max]u8 = undefined;
    while (true) : (seed += 1) {
        const swarm = runner.generate(.synthetic, seed, null, &buffer).swarm;
        if (swarm.lines.contains(.glue) and !swarm.terms.contains(.random)) break;
    }
    const regression: runner.Regression = .{ .target = .synthetic, .seed = seed };
    const request: Request = .{ .regression = regression, .bound = .{ .calls_max = 1000 } };
    const result = (try run(gpa, arena, request)).?;
    try std.testing.expectEqualStrings("synthetic", result.reason);
    try std.testing.expect(!result.stopped);
    try std.testing.expect(result.swarm.?.lines.contains(.glue));
    try std.testing.expect(result.features_after < result.features_before);
    try std.testing.expect(result.lines_before > 10);
    try std.testing.expectEqual(@as(u32, 0), result.lines_after);
    // A seed that passes has nothing to reduce.
    seed = 1;
    while (true) : (seed += 1) {
        if (!runner.generate(.synthetic, seed, null, &buffer).swarm.lines.contains(.glue)) break;
    }
    const passing: Request = .{
        .regression = .{ .target = .synthetic, .seed = seed },
        .bound = .{ .calls_max = 1000 },
    };
    try std.testing.expectEqual(null, try run(gpa, arena, passing));
}

test "a synthetic host failure on a large story reduces to a few lines, within its bound" {
    // P19.7: the synthetic host target fails when its mix takes a set_variable, which its
    // first turn's roll does for some seeds whatever the story: a story of many lines
    // reduces to a few, and replaying the reduced story fails the same. A bound of 3 calls
    // stops the reduction with a story that still fails.
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buffer: [fuzz_ink.source_bytes_max]u8 = undefined;
    var seed: u64 = 1;
    const large = while (true) : (seed += 1) {
        const case = runner.generate(.host_synthetic, seed, null, &buffer);
        if (count_lines(case.source) < 40) continue;
        const regression = regression_of(.host_synthetic, seed);
        const failure = try runner.replay(gpa, regression, case.source) orelse continue;
        try std.testing.expectEqualStrings("synthetic set_variable", failure);
        break try arena.dupe(u8, case.source);
    };
    const regression = regression_of(.host_synthetic, seed);
    const request: Request = .{
        .regression = regression,
        .story = large,
        .bound = .{ .calls_max = 2000 },
    };
    const result = (try run(gpa, arena, request)).?;
    try std.testing.expectEqualStrings("synthetic set_variable", result.reason);
    try std.testing.expect(result.swarm == null);
    try std.testing.expect(!result.stopped);
    try std.testing.expect(result.lines_before >= 40);
    // Chunks are halved at fixed offsets, so a knot and its one line can stay when only
    // dropping both at once keeps the story compiling (P19.8's generator: 10 lines left).
    try std.testing.expect(result.lines_after <= 10);
    const again = (try runner.replay(gpa, regression, result.source)).?;
    try std.testing.expectEqualStrings("synthetic set_variable", again);

    var bounded = request;
    bounded.bound.calls_max = 3;
    const stopped = (try run(gpa, arena, bounded)).?;
    try std.testing.expect(stopped.stopped);
    try std.testing.expectEqual(@as(u32, 3), stopped.calls);
    try std.testing.expect(try runner.replay(gpa, regression, stopped.source) != null);
}

fn regression_of(target: runner.Target, seed: u64) runner.Regression {
    return .{ .target = target, .seed = seed, .mix = runner.drawn_mix(seed) };
}

test "an isolated check reads the child's reason, and a crash's frame" {
    // P19.7: `dev swarm --story` in a child process: the synthetic host failure's reason;
    // a pass; and the frame a crash names.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/candidate.ink", .{tmp.sub_path});
    var buffer: [fuzz_ink.source_bytes_max]u8 = undefined;
    var seed: u64 = 1;
    const source = while (true) : (seed += 1) {
        const case = runner.generate(.host_synthetic, seed, null, &buffer);
        if (try runner.replay(gpa, regression_of(.host_synthetic, seed), case.source) != null) {
            break case.source;
        }
    };
    var request: Request = .{
        .regression = regression_of(.host_synthetic, seed),
        .isolated = io,
        .candidate_path = path,
        .bound = .{ .calls_max = 1 },
    };
    const reason = (try check_isolated(arena, io, request, source)).?;
    try std.testing.expectEqualStrings("synthetic set_variable", reason);
    request.regression.target = .host;
    try std.testing.expectEqual(null, try check_isolated(arena, io, request, source));
    const stderr = "thread 1 panic: reached unreachable code\n" ++
        "/zig/lib/std/debug.zig:420:14: 0x1 in assert (dev)\n" ++
        "/repo/src/runtime/vm.zig:12:5: 0x2 in step (dev)\n";
    const crash = try crash_reason(arena, stderr, .{ .signal = .ABRT });
    const expected = "reached unreachable code in assert (dev), at src/runtime/vm.zig:12:5 " ++
        "in step (dev)";
    try std.testing.expectEqualStrings(expected, crash);
}
