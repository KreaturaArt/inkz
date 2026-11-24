//! The development tool, one program with a subcommand per job, run from the repository
//! root by the build step of the same name (`zig build <command> -- <arguments>`):
//!
//! - `replay <case id> [--actions <text>]` or `replay --json <story.ink.json> --actions
//!   <text>`: replays one story and prints its transcript. The gates start it once per story
//!   (src/testing/isolated.zig), so a crash is contained in that process.
//! - `simulate ...`: seeded random play of the ground-truth cases (src/simulate.zig).
//! - `transcripts`: regenerates `test/transcripts/` from the runtime.
//! - `swarm --target <compile|play|save|host|mutate|all> [--seed S] [--seeds N]
//!   [--seconds T] [--mix <hex>]`: seeded swarm runs out of the fuzzer
//!   (src/testing/swarm_runner.zig), `all` being play, save, host and mutate; `--mix` replays
//!   a host failure's mix. Writes each failing case's story to zig-out/swarm/regressions
//!   and prints its entry for test/swarm_regressions.zon. Exits with 1 when a run failed.
//!   With `--story <file>`, replays the seed of one target on that story instead, printing
//!   `replay: failure (<reason>)` (and exiting with 1) or `replay: pass`; with `--reduce
//!   <file|seed>`, reduces the seed's failure on that story, or on its case, for `--seconds`
//!   (60 by default; src/testing/swarm_reduce.zig).
//! - `swarm-gen`, `swarm-check`, `swarm-reduce`: the differential swarm run
//!   (src/swarm_differential.zig).

const std = @import("std");
const assert = std.debug.assert;
const cases = @import("testing/cases.zig");
const transcripts = @import("testing/transcripts.zig");
const runner = @import("testing/swarm_runner.zig");
const simulate = @import("simulate.zig");
const simulation = @import("testing/simulation.zig");
const swarm_differential = @import("swarm_differential.zig");
const swarm_mutate = @import("testing/swarm_mutate.zig");
const swarm_reducer = @import("testing/swarm_reduce.zig");
const fuzz_ink = @import("testing/fuzz_ink.zig");
const coverage = @import("testing/coverage.zig");
const build_options = @import("build_options");

comptime {
    if (build_options.coverage) coverage.reference_library();
}

/// The default panic, after the seed a swarm run was on (`runner.running`), so a crash
/// can be reproduced.
pub const panic = std.debug.FullPanic(panic_with_seed);

fn panic_with_seed(message: []const u8, first_trace_address: ?usize) noreturn {
    if (runner.running) |at| {
        std.debug.print("swarm {t}: panic in seed {d}; reproduce with: zig build swarm " ++
            "-Doptimize=ReleaseSafe -- --target {t} --seed {d} --seeds 1\n", .{
            at.target, at.seed, at.target, at.seed,
        });
    }
    std.debug.defaultPanic(message, first_trace_address);
}

const Command = enum {
    replay,
    simulate,
    transcripts,
    swarm,
    @"swarm-gen",
    @"swarm-check",
    @"swarm-reduce",
};

const usage =
    \\usage: dev <command> [arguments]: replay, simulate, transcripts, swarm, swarm-gen,
    \\       swarm-check or swarm-reduce (see src/dev.zig)
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(arena);
    const command = if (argv.len >= 2) std.meta.stringToEnum(Command, argv[1]) else null;
    // Each command reads its arguments after its own name.
    const arguments = argv[1..];
    switch (command orelse {
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    }) {
        .replay => try replay(arena, io, arguments),
        .simulate => try simulate.command(arena, io, arguments),
        .transcripts => {
            assert(transcripts.actions.len > 0);
            const count = try transcripts.write_all(arena, io);
            assert(count > 0);
            const directory = transcripts.transcripts_directory;
            std.debug.print("wrote {d} transcripts to {s}\n", .{ count, directory });
        },
        .swarm => try swarm(arena, init.gpa, io, arguments),
        .@"swarm-gen", .@"swarm-check", .@"swarm-reduce" => {
            try swarm_differential.command(arena, io, arguments);
        },
    }
}

fn replay(arena: std.mem.Allocator, io: std.Io, arguments: []const [:0]const u8) !void {
    assert(arguments.len > 0);
    const text = if (arguments.len == 2)
        try cases.replay_case(arena, io, arguments[1], null)
    else if (arguments.len == 4 and std.mem.eql(u8, arguments[2], "--actions"))
        try cases.replay_case(arena, io, arguments[1], arguments[3])
    else if (arguments.len == 5 and std.mem.eql(u8, arguments[1], "--json") and
        std.mem.eql(u8, arguments[3], "--actions"))
        try cases.replay_json(arena, io, arguments[2], arguments[4])
    else {
        std.debug.print("usage: dev replay <case id> [--actions <text>]\n" ++
            "       dev replay --json <story.ink.json> --actions <text>\n", .{});
        std.process.exit(2);
    };
    var buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(io, &buffer);
    try file_writer.interface.writeAll(text);
    try file_writer.interface.flush();
}

/// `swarm`'s options.
const SwarmOptions = struct {
    /// Null: play, save, host and mutate in turn, sharing the time budget. Play and save
    /// check the compiled program as the compile target does, so `all` leaves that one out.
    target: ?runner.Target = .play,
    mix: ?simulation.Mix = null,
    seed: u64 = 1,
    seeds: ?u32 = null,
    seconds: ?u32 = null,
    /// Replays the seed on this story (`runner.replay`) instead of running seeds.
    story: ?[]const u8 = null,
    /// Reduces the seed's failure (`swarm_reduce`): on this story, or `seed` for its case.
    reduce: ?[]const u8 = null,

    fn parse(arguments: []const [:0]const u8) !SwarmOptions {
        assert(arguments.len > 0);
        var options: SwarmOptions = .{};
        var index: usize = 1;
        // Options come in pairs: a flag without its value is an error, not ignored.
        if (arguments.len % 2 == 0) return error.MissingValue;
        while (index + 1 < arguments.len) : (index += 2) {
            const name = arguments[index];
            const value = arguments[index + 1];
            if (std.mem.eql(u8, name, "--target")) {
                options.target = if (std.mem.eql(u8, value, "all"))
                    null
                else
                    std.meta.stringToEnum(runner.Target, value) orelse
                        return error.UnknownTarget;
            } else if (std.mem.eql(u8, name, "--seed")) {
                options.seed = try std.fmt.parseInt(u64, value, 10);
            } else if (std.mem.eql(u8, name, "--seeds")) {
                options.seeds = try std.fmt.parseInt(u32, value, 10);
            } else if (std.mem.eql(u8, name, "--seconds")) {
                options.seconds = try std.fmt.parseInt(u32, value, 10);
            } else if (std.mem.eql(u8, name, "--mix")) {
                options.mix = try simulation.Mix.decode(try std.fmt.parseInt(u64, value, 16));
            } else if (std.mem.eql(u8, name, "--story")) {
                options.story = value;
            } else if (std.mem.eql(u8, name, "--reduce")) {
                options.reduce = value;
            } else return error.UnknownOption;
        }
        const one_seed = options.story != null or options.reduce != null;
        if (one_seed and options.target == null) return error.OneTargetNeeded;
        if (options.story != null and options.reduce != null) return error.StoryOrReduce;
        return options;
    }

    /// The seed's entry, its mix the one given or drawn.
    fn regression(options: SwarmOptions) runner.Regression {
        const target = options.target.?;
        const mix: ?u64 = if (!target.hosts())
            null
        else if (options.mix) |mix| mix.encode() else runner.drawn_mix(options.seed);
        return .{ .target = target, .seed = options.seed, .mix = mix };
    }
};

/// `swarm --story`: prints `replay: failure (<reason>)` and exits with 1, or `replay: pass`.
fn swarm_replay(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    options: SwarmOptions,
) !void {
    const limit: std.Io.Limit = .limited(fuzz_ink.source_bytes_max);
    const source = try std.Io.Dir.cwd().readFileAlloc(io, options.story.?, arena, limit);
    const failure = try runner.replay(gpa, options.regression(), source);
    var buffer: [256]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(io, &buffer);
    if (failure) |reason| {
        try file_writer.interface.print("replay: failure ({s})\n", .{reason});
    } else try file_writer.interface.writeAll("replay: pass\n");
    try file_writer.interface.flush();
    if (failure != null) std.process.exit(1);
}

/// `swarm --reduce`: reduces the seed's failure, each check in a child process (but the
/// synthetic target's), for `--seconds` (60 by default), and writes the reduced story next
/// to the stories of failing runs.
fn swarm_reduce(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    options: SwarmOptions,
) !void {
    const regression = options.regression();
    const target = regression.target;
    const cwd = std.Io.Dir.cwd();
    const limit: std.Io.Limit = .limited(fuzz_ink.source_bytes_max);
    const reduce = options.reduce.?;
    const from_seed = std.mem.eql(u8, reduce, "seed");
    const story = if (from_seed) null else try cwd.readFileAlloc(io, reduce, arena, limit);
    if (target == .synthetic and story != null) return error.SyntheticReducesFromItsSeed;
    var corpus: ?swarm_mutate.Corpus = null;
    if (target == .mutate and story == null) corpus = try swarm_mutate.Corpus.load(arena, io);
    try cwd.createDirPath(io, runner.regressions_out);
    const name = try std.fmt.allocPrint(arena, "{s}/{t}-{d}", .{
        runner.regressions_out,
        target,
        regression.seed,
    });
    const seconds: i96 = options.seconds orelse 60;
    const started = std.Io.Timestamp.now(io, .awake);
    const deadline = started.nanoseconds + seconds * std.time.ns_per_s;
    const request: swarm_reducer.Request = .{
        .regression = regression,
        .story = story,
        .corpus = if (corpus) |*loaded| loaded else null,
        .isolated = if (target == .synthetic) null else io,
        .candidate_path = try std.fmt.allocPrint(arena, "{s}.candidate.ink", .{name}),
        .bound = .{
            .calls_max = 100_000,
            .deadline = .{ .nanoseconds = deadline },
            .io = io,
        },
    };
    var buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(io, &buffer);
    const writer = &file_writer.interface;
    const result = try swarm_reducer.run(gpa, arena, request) orelse {
        try writer.print("swarm {t}: seed {d} doesn't fail\n", .{ target, regression.seed });
        try writer.flush();
        std.process.exit(1);
    };
    const out_path = try std.fmt.allocPrint(arena, "{s}.reduced.ink", .{name});
    try cwd.writeFile(io, .{ .sub_path = out_path, .data = result.source });
    const elapsed = started.untilNow(io, .awake).toMilliseconds();
    try writer.print("swarm {t}: reduced seed {d} in {d} ms: {f}; wrote {s}; its entry: {f}\n", .{
        target,
        regression.seed,
        elapsed,
        result,
        out_path,
        regression,
    });
    try writer.flush();
}

fn swarm(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    arguments: []const [:0]const u8,
) !void {
    const options: SwarmOptions = try .parse(arguments);
    if (options.story != null) return swarm_replay(arena, gpa, io, options);
    if (options.reduce != null) return swarm_reduce(arena, gpa, io, options);
    const target = options.target;
    const seed = options.seed;
    const seconds = options.seconds;
    // Play gets 4 twelfths of the time, save and host 3 each, mutate 2: play's seeds also
    // play again under other limits, host's spend most of theirs on the host calls, and
    // mutate reaches its coverage in a few seconds (docs/fuzzing.md).
    const all: []const runner.Target = &.{ .play, .save, .host, .mutate };
    const all_shares: []const u64 = &.{ 4, 3, 3, 2 };
    const targets: []const runner.Target = if (target) |one| &.{one} else all;
    // The ground-truth stories are read once, for the whole run.
    var corpus: ?swarm_mutate.Corpus = null;
    for (targets) |each| {
        if (each == .mutate) corpus = try swarm_mutate.Corpus.load(arena, io);
    }
    const shares: []const u64 = if (target == null) all_shares else &.{1};
    var shares_total: u64 = 0;
    for (shares) |share| shares_total += share;
    var shares_done: u64 = 0;
    var buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(io, &buffer);
    var failures: u32 = 0;
    const started = std.Io.Timestamp.now(io, .awake);
    assert(targets.len == shares.len);
    for (targets, shares) |each, share| {
        const seeds_default: u32 = if (seconds == null) 1000 else std.math.maxInt(u32);
        var budget: runner.Budget = .{ .seeds = options.seeds orelse seeds_default };
        shares_done += share;
        if (seconds) |total| {
            // Each target ends at its share of the total and the shares before it.
            const end_ns = @as(u64, total) * std.time.ns_per_s * shares_done / shares_total;
            budget.deadline = .{ .nanoseconds = started.nanoseconds + end_ns };
            budget.io = io;
        }
        try file_writer.interface.print("swarm {t}: first seed {d}\n", .{ each, seed });
        try file_writer.interface.flush();
        const inputs: runner.Inputs = .{
            .mix = options.mix,
            .corpus = if (each == .mutate) &corpus.? else null,
            .io = io,
        };
        const summary = try runner.run(gpa, &file_writer.interface, each, seed, budget, inputs);
        failures += summary.failures;
    }
    // The coverage build (`zig build swarm-coverage`) reports what the run reached.
    if (build_options.coverage) {
        const path = "zig-out/coverage/swarm.txt";
        try coverage.write_report(io, path, &file_writer.interface);
        try file_writer.interface.print("coverage: wrote {s}\n", .{path});
    }
    try file_writer.interface.flush();
    if (failures > 0) std.process.exit(1);
}
