//! The development tool, one program with a subcommand per job, run from the repository
//! root by the build step of the same name (`zig build <command> -- <arguments>`):
//!
//! - `replay <case id> [--actions <text>]` or `replay --json <story.ink.json> --actions
//!   <text>`: replays one story and prints its transcript. The gates start it once per story
//!   (src/testing/isolated.zig), so a crash is contained in that process.
//! - `simulate ...`: seeded random play of the ground-truth cases (src/simulate.zig).
//! - `transcripts`: regenerates `test/transcripts/` from the runtime.
//! - `swarm --target <compile|play|save|all> [--seed S] [--seeds N] [--seconds T]`: seeded
//!   swarm runs out of the fuzzer (src/testing/swarm_runner.zig), `all` being play and save;
//!   exits with 1 when a run failed.
//! - `swarm-gen`, `swarm-check`, `swarm-reduce`: the differential swarm run
//!   (src/swarm_differential.zig).

const std = @import("std");
const assert = std.debug.assert;
const cases = @import("testing/cases.zig");
const transcripts = @import("testing/transcripts.zig");
const runner = @import("testing/swarm_runner.zig");
const simulate = @import("simulate.zig");
const swarm_differential = @import("swarm_differential.zig");

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
        .swarm => try swarm(init.gpa, io, arguments),
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

fn swarm(gpa: std.mem.Allocator, io: std.Io, arguments: []const [:0]const u8) !void {
    assert(arguments.len > 0);
    // Null target: play and save in turn, sharing the time budget. Both check the compiled
    // program as the compile target does, so `all` leaves that one out.
    var target: ?runner.Target = .play;
    var seed: u64 = 1;
    var seeds: ?u32 = null;
    var seconds: ?u32 = null;
    var index: usize = 1;
    while (index + 1 < arguments.len) : (index += 2) {
        const name = arguments[index];
        const value = arguments[index + 1];
        if (std.mem.eql(u8, name, "--target")) {
            target = if (std.mem.eql(u8, value, "all"))
                null
            else
                std.meta.stringToEnum(runner.Target, value) orelse return error.UnknownTarget;
        } else if (std.mem.eql(u8, name, "--seed")) {
            seed = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, name, "--seeds")) {
            seeds = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, name, "--seconds")) {
            seconds = try std.fmt.parseInt(u32, value, 10);
        } else return error.UnknownOption;
    }
    const all: []const runner.Target = &.{ .play, .save };
    const targets: []const runner.Target = if (target) |one| &.{one} else all;
    var buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(io, &buffer);
    var failures: u32 = 0;
    const started = std.Io.Timestamp.now(io, .awake);
    for (targets, 0..) |each, position| {
        const seeds_default: u32 = if (seconds == null) 1000 else std.math.maxInt(u32);
        var budget: runner.Budget = .{ .seeds = seeds orelse seeds_default };
        if (seconds) |total| {
            // Target number n ends at n/len of the total, so all of them share it evenly.
            const share_ns = @as(u64, total) * std.time.ns_per_s * (position + 1) / targets.len;
            budget.deadline = .{ .nanoseconds = started.nanoseconds + share_ns };
            budget.io = io;
        }
        try file_writer.interface.print("swarm {t}: first seed {d}\n", .{ each, seed });
        const summary = try runner.run(gpa, &file_writer.interface, each, seed, budget);
        failures += summary.failures;
    }
    try file_writer.interface.flush();
    if (failures > 0) std.process.exit(1);
}
