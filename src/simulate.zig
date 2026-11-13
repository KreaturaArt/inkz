//! `zig build simulate -- [--seed 1] [--seeds 10] [--case <id> | --json <path>]
//! [--compact-always on] [--fit on]`: plays every ground-truth case (or one, or a story's
//! JSON file) with seeded random choices for each seed and reports failures with the
//! command that reproduces them. Exits with 1 if any run failed.
//!
//! `--fit on` measures each story's peak usage over the seeds, prints `Limits.fitted(usage,
//! 2)` as Zig source with its byte budget, then plays the same seeds again within those
//! limits; a run that hits a limit there is a failure.
//!
//! The runtime runs in process with the full action mix (save and load points, flow switches,
//! evaluate_function, set_variable) and State.check after every cont; `--compact-always on`
//! compacts the heap before every allocation.

const std = @import("std");
const assert = std.debug.assert;
const simulation = @import("testing/simulation.zig");
const cases = @import("testing/cases.zig");

const Options = struct {
    seed_first: i32 = 1,
    seeds_count: u32 = 10,
    case: ?[]const u8 = null,
    json: ?[]const u8 = null,
    compact_always: bool = false,
    fit: bool = false,
};

fn parse_options(arguments: []const [:0]const u8) !Options {
    assert(arguments.len > 0);
    var options: Options = .{};
    var index: usize = 1;
    while (index + 1 < arguments.len) : (index += 2) {
        const name = arguments[index];
        const value = arguments[index + 1];
        if (std.mem.eql(u8, name, "--seed")) {
            options.seed_first = try std.fmt.parseInt(i32, value, 10);
        } else if (std.mem.eql(u8, name, "--seeds")) {
            options.seeds_count = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, name, "--case")) {
            options.case = value;
        } else if (std.mem.eql(u8, name, "--json")) {
            options.json = value;
        } else if (std.mem.eql(u8, name, "--fit")) {
            options.fit = std.mem.eql(u8, value, "on");
        } else if (std.mem.eql(u8, name, "--compact-always")) {
            options.compact_always = std.mem.eql(u8, value, "on");
        } else return error.UnknownOption;
    }
    if (index != arguments.len) return error.MissingOptionValue;
    if (options.case) |case| assert(case.len > 0);
    return options;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const options = try parse_options(try init.minimal.args.toSlice(arena));
    const ids: []const []const u8 = if (options.json) |path|
        try arena.dupe([]const u8, &.{path})
    else if (options.case) |case|
        try arena.dupe([]const u8, &.{case})
    else
        try cases.ids(arena, io);
    try simulate(arena, io, ids, options);
}

/// Each case's program is loaded once and played for every seed.
fn simulate(
    arena: std.mem.Allocator,
    io: std.Io,
    ids: []const []const u8,
    options: Options,
) !void {
    assert(ids.len > 0);
    const gpa = std.heap.smp_allocator;
    const save_buffer = try arena.alloc(u8, 4 << 20);
    var totals: Totals = .{};
    for (ids) |id| {
        const path = if (options.json != null)
            id
        else
            try std.fmt.allocPrint(arena, "test/ground_truth/{s}.ink.json", .{id});
        const json = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 << 20));
        var program = ink_json.load(gpa, json) catch continue;
        defer program.deinit(gpa);
        const run: Run = .{ .id = id, .program = &program, .save_buffer = save_buffer };
        const usage = try run.play(gpa, .{}, options, &totals);
        if (!options.fit) continue;
        const limits = limits_module.fitted(usage, 2);
        try print_fitted(arena, id, limits, limits.bytes_total(State.shape_of(&program)));
        _ = try run.play(gpa, limits, options, &totals);
    }
    std.debug.print("simulate ({s}{s}): {d} runs over {d} seeds, {d} failures\n", .{
        if (options.compact_always) "compact always" else "plain",
        if (options.fit) ", fitted limits" else "",
        totals.runs,
        options.seeds_count,
        totals.failures,
    });
    if (totals.failures > 0) std.process.exit(1);
}

const Totals = struct { runs: u64 = 0, failures: u32 = 0 };

/// One story's seeds on one set of limits.
const Run = struct {
    id: []const u8,
    program: *const Program,
    save_buffer: []u8,

    /// Plays every seed; returns the story's usage over all of them.
    fn play(
        run: *const Run,
        gpa: std.mem.Allocator,
        limits: Limits,
        options: Options,
        totals: *Totals,
    ) !limits_module.Usage {
        assert(options.seeds_count > 0);
        var story: Story = undefined;
        try story.init(gpa, run.program, limits);
        defer story.deinit(gpa);
        simulation.prepare(&story, options.compact_always);
        for (0..options.seeds_count) |offset| {
            const seed = options.seed_first +% @as(i32, @intCast(offset));
            totals.runs += 1;
            const result = simulation.simulate(&story, seed, run.save_buffer);
            const finding = result catch |err| switch (err) {
                error.StepLimit => simulation.Finding.ok,
                else => if (options.fit) {
                    totals.failures += 1;
                    std.debug.print("{t}: seed {d}, {s}\n", .{ err, seed, run.id });
                    continue;
                } else return err,
            };
            if (finding == .ok) continue;
            totals.failures += 1;
            std.debug.print("{t}: seed {d}, case {s}; reproduce with: zig build simulate -- " ++
                "--seed {d} --seeds 1 --case {s} --compact-always {s}\n", .{
                finding, seed, run.id, seed, run.id, if (options.compact_always) "on" else "off",
            });
        }
        assert(totals.failures <= totals.runs);
        return story.usage();
    }
};

/// The fitted limits as Zig source, ready to paste.
fn print_fitted(arena: std.mem.Allocator, id: []const u8, limits: Limits, bytes: u64) !void {
    assert(id.len > 0);
    assert(bytes > 0);
    var text: std.Io.Writer.Allocating = .init(arena);
    const writer = &text.writer;
    try writer.print("// {s}: Limits.fitted(usage, 2), {d} bytes per story\n", .{ id, bytes });
    try writer.writeAll("const limits: inkz.Limits = .{\n");
    inline for (@typeInfo(Limits).@"struct".field_names) |name| {
        try writer.print("    .{s} = {d},\n", .{ name, @field(limits, name) });
    }
    try writer.writeAll("};\n");
    std.debug.print("{s}", .{text.written()});
}

const ink_json = @import("core/ink_json.zig");
const Story = @import("runtime/story.zig").Story;
const Program = @import("core/program.zig").Program;
const limits_module = @import("core/limits.zig");
const Limits = limits_module.Limits;
const State = @import("runtime/state.zig").State;
