//! `zig build simulate -- [--engine old] [--seed 1] [--seeds 10] [--case <id>]` (plan P0.9):
//! plays every ground-truth case (or one) with seeded random choices for each seed and reports
//! crashes with the command that reproduces them. Exits with 1 if any run crashed.

const std = @import("std");
const assert = std.debug.assert;
const simulation = @import("testing/simulation.zig");
const ground_truth = @import("testing/ground_truth_test.zig");

const Options = struct {
    engine: []const u8 = "old",
    seed_first: i32 = 1,
    seeds_count: u32 = 10,
    case: ?[]const u8 = null,
};

fn parse_options(arguments: []const [:0]const u8) !Options {
    assert(arguments.len > 0);
    var options: Options = .{};
    var index: usize = 1;
    while (index + 1 < arguments.len) : (index += 2) {
        const name = arguments[index];
        const value = arguments[index + 1];
        if (std.mem.eql(u8, name, "--engine")) {
            options.engine = value;
        } else if (std.mem.eql(u8, name, "--seed")) {
            options.seed_first = try std.fmt.parseInt(i32, value, 10);
        } else if (std.mem.eql(u8, name, "--seeds")) {
            options.seeds_count = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, name, "--case")) {
            options.case = value;
        } else return error.UnknownOption;
    }
    if (index != arguments.len) return error.MissingOptionValue;
    assert(options.engine.len > 0);
    if (options.case) |case| assert(case.len > 0);
    return options;
}

pub fn main(init: std.process.Init) !void {
    assert(simulation.Outcome.ok != simulation.Outcome.crash);
    const arena = init.arena.allocator();
    const io = init.io;
    const options = try parse_options(try init.minimal.args.toSlice(arena));
    const ids: []const []const u8 = if (options.case) |case|
        try arena.dupe([]const u8, &.{case})
    else
        try ground_truth.collect_cases(arena, io);
    var runs: u32 = 0;
    var crashes: u32 = 0;
    for (0..options.seeds_count) |offset| {
        const seed = options.seed_first +% @as(i32, @intCast(offset));
        for (ids) |id| {
            const run = try simulation.run_seed(arena, io, options.engine, id, seed);
            runs += 1;
            if (run.outcome == .ok) continue;
            crashes += 1;
            std.debug.print("crash: engine {s}, seed {d}, case {s}; reproduce with: " ++
                "zig build simulate -- --engine {s} --seed {d} --seeds 1 --case {s}\n", .{
                options.engine, seed, id, options.engine, seed, id,
            });
        }
    }
    assert(crashes <= runs);
    std.debug.print("simulate ({s}): {d} runs over {d} seeds, {d} crashes\n", .{
        options.engine, runs, options.seeds_count, crashes,
    });
    if (crashes > 0) std.process.exit(1);
}
