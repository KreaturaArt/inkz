//! `zig build simulate -- [--engine new] [--seed 1] [--seeds 10] [--case <id>]
//! [--compact-always on]` (plan P0.9, P5.12): plays every ground-truth case (or one) with
//! seeded random choices for each seed and reports failures with the command that reproduces
//! them. Exits with 1 if any run failed.
//!
//! The engine runs in process with the full action mix (save and load points, flow switches,
//! evaluate_function, set_variable) and State.check after every cont; `--compact-always on`
//! compacts the heap before every allocation.

const std = @import("std");
const assert = std.debug.assert;
const simulation = @import("testing/simulation.zig");
const ground_truth = @import("testing/ground_truth_test.zig");

const Options = struct {
    engine: []const u8 = "new",
    seed_first: i32 = 1,
    seeds_count: u32 = 10,
    case: ?[]const u8 = null,
    compact_always: bool = false,
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
        } else if (std.mem.eql(u8, name, "--compact-always")) {
            options.compact_always = std.mem.eql(u8, value, "on");
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
    if (std.mem.eql(u8, options.engine, "new")) return simulate_new(arena, io, ids, options);
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

/// The new engine, in process: each case's program is loaded once and played for every seed.
fn simulate_new(
    arena: std.mem.Allocator,
    io: std.Io,
    ids: []const []const u8,
    options: Options,
) !void {
    assert(ids.len > 0);
    const gpa = std.heap.smp_allocator;
    const save_buffer = try arena.alloc(u8, 4 << 20);
    var runs: u64 = 0;
    var failures: u32 = 0;
    for (ids) |id| {
        const path = try std.fmt.allocPrint(arena, "test/ground_truth/{s}.ink.json", .{id});
        const json = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 << 20));
        var program = ink_json.load(gpa, json) catch continue;
        defer program.deinit(gpa);
        var story: Story = undefined;
        try story.init(gpa, &program, .{});
        defer story.deinit(gpa);
        simulation.prepare_new(&story, options.compact_always);
        for (0..options.seeds_count) |offset| {
            const seed = options.seed_first +% @as(i32, @intCast(offset));
            runs += 1;
            const result = simulation.simulate_new(&story, seed, save_buffer);
            const finding = result catch |err| switch (err) {
                error.StepLimit => simulation.Finding.ok,
                else => return err,
            };
            if (finding == .ok) continue;
            failures += 1;
            std.debug.print("{t}: seed {d}, case {s}; reproduce with: zig build simulate -- " ++
                "--engine new --seed {d} --seeds 1 --case {s} --compact-always {s}\n", .{
                finding, seed, id, seed, id, if (options.compact_always) "on" else "off",
            });
        }
    }
    std.debug.print("simulate (new{s}): {d} runs over {d} seeds, {d} failures\n", .{
        if (options.compact_always) ", compact always" else "", runs, options.seeds_count, failures,
    });
    if (failures > 0) std.process.exit(1);
}

const ink_json = @import("core/ink_json.zig");
const Story = @import("runtime/story.zig").Story;
