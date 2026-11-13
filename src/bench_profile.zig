//! `zig build bench-profile` (TASK-153): where the pipeline spends its time. Each workload
//! (compile, JSON load and store, image load and store, story init, play, save, load a save)
//! runs on crime_scene and on the generated 1000-knot story, with the profile zones of
//! src/core/profile.zig compiled in. For each workload it prints every zone's exclusive and
//! inclusive time per iteration and its share of the workload's wall time, then the worst
//! zones of one pass through the whole pipeline. The records are appended to
//! `bench/profile.jsonl`, one JSON object per line and zone.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const profile = @import("core/profile.zig");
const compile = @import("compiler/compile.zig");
const ink_json = @import("core/ink_json.zig");
const program_image = @import("core/program_image.zig");
const Program = @import("core/program.zig").Program;
const Story = @import("runtime/story.zig").Story;
const save = @import("runtime/save.zig");
const load = @import("runtime/load.zig");
const Severity = @import("runtime/state.zig").Diagnostic.Severity;
const DotnetRandom = @import("core/dotnet_random.zig").DotnetRandom;
const bench_io = @import("bench_io.zig");

/// Compiles the profile zones in (src/core/profile.zig).
pub const inkz_profile = true;

const Allocator = std.mem.Allocator;
const results_path = "bench/profile.jsonl";
const iterations_min = 3;
const iterations_max = 10_000;
const budget_nanoseconds = 1_000_000_000;
const turns_max = 200;
const contenders_shown = 12;

const Subject = struct {
    name: []const u8,
    source_path: []const u8,
    json_path: []const u8,
};
const subjects = [_]Subject{
    .{
        .name = "crime_scene",
        .source_path = "test/fixture/crime_scene.ink",
        .json_path = "test/ground_truth/crime_scene.ink.json",
    },
    .{
        .name = "generated_1000_knots",
        .source_path = "test/fixture/bench/generated.ink",
        .json_path = "test/fixture/bench/generated.ink.json",
    },
};

pub const Workload = enum {
    compile,
    json_load,
    json_store,
    image_load,
    image_store,
    story_init,
    play,
    save,
    load_save,
};

/// One workload's measurement: wall time and the zones' totals, over `iterations`, and the
/// wall time per iteration of the same workload with the zones off.
pub const Measurement = struct {
    workload: Workload,
    iterations: u32,
    wall_ns: u64,
    totals: profile.Totals,
    plain_ns_per_iteration: f64,
};

/// One line of the results file: a zone of a workload, per iteration.
pub const Record = struct {
    timestamp: []const u8,
    commit: []const u8,
    dirty: bool,
    zig: []const u8,
    mode: []const u8,
    target: []const u8,
    cpu: []const u8,
    story: []const u8,
    workload: Workload,
    /// A zone's name, or "(outside zones)" for the wall time no zone covers.
    zone: []const u8,
    iterations: u32,
    wall_ns_per_iteration: f64,
    /// The same workload with the zones off; the difference is the profiler's cost.
    plain_wall_ns_per_iteration: f64,
    calls_per_iteration: f64,
    exclusive_ns_per_iteration: f64,
    inclusive_ns_per_iteration: f64,
    /// Exclusive time over the workload's (profiled) wall time.
    share: f64,
};

fn ignore_message(context: ?*anyopaque, message: []const u8, severity: Severity) void {
    assert(context == null);
    assert(message.len > 0 or severity == .warning);
}

/// What the workloads run on, made once per story.
const Inputs = struct {
    gpa: Allocator,
    source: []const u8,
    json: []const u8,
    program: Program,
    image: []u8,
    out: std.Io.Writer.Allocating,
    /// Played to its end once, for `save`; `loader` loads its save.
    played: Story,
    loader: Story,
    save_json: []u8,

    fn prepare(inputs: *Inputs, gpa: Allocator, source: []const u8, json: []const u8) !void {
        assert(source.len > 0);
        assert(json.len > 0);
        inputs.* = .{
            .gpa = gpa,
            .source = source,
            .json = json,
            .program = try ink_json.load(gpa, json),
            .image = undefined,
            .out = .init(gpa),
            .played = undefined,
            .loader = undefined,
            .save_json = undefined,
        };
        try program_image.write(&inputs.program, &inputs.out.writer);
        inputs.image = try gpa.dupe(u8, inputs.out.written());
        try inputs.played.init(gpa, &inputs.program, .{});
        inputs.played.on_error = ignore_message;
        try play_once(&inputs.played, 1);
        inputs.out.clearRetainingCapacity();
        try save.to_json(&inputs.played, &inputs.out.writer);
        inputs.save_json = try gpa.dupe(u8, inputs.out.written());
        try inputs.loader.init(gpa, &inputs.program, .{});
        inputs.loader.on_error = ignore_message;
    }

    fn deinit(inputs: *Inputs) void {
        assert(inputs.image.len > 0);
        assert(inputs.save_json.len > 0);
        const gpa = inputs.gpa;
        inputs.loader.deinit(gpa);
        inputs.played.deinit(gpa);
        gpa.free(inputs.save_json);
        gpa.free(inputs.image);
        inputs.out.deinit();
        inputs.program.deinit(gpa);
        inputs.* = undefined;
    }
};

/// One play from the start: seeded choices, as `zig build bench` plays.
fn play_once(story: *Story, seed: u32) !void {
    assert(seed > 0);
    try story.reset_state();
    var random = DotnetRandom.init(@intCast(seed));
    var turn: u32 = 0;
    while (turn < turns_max) : (turn += 1) {
        while (story.can_continue()) _ = try story.cont();
        const count = story.visible_choices_count();
        if (count == 0) break;
        try story.choose_choice_index(@intCast(@mod(random.next(), @as(i32, @intCast(count)))));
    }
    assert(turn <= turns_max);
}

fn run_once(inputs: *Inputs, workload: Workload, iteration: u32) !void {
    assert(inputs.image.len > 0);
    assert(iteration < iterations_max);
    const gpa = inputs.gpa;
    inputs.out.clearRetainingCapacity();
    switch (workload) {
        .compile => {
            var program = try compile.compile_source(gpa, inputs.source);
            program.deinit(gpa);
        },
        .json_load => {
            var program = try ink_json.load(gpa, inputs.json);
            program.deinit(gpa);
        },
        .json_store => try ink_json.serialize(gpa, &inputs.program, &inputs.out.writer),
        .image_load => {
            var program = try program_image.load(gpa, inputs.image);
            program.deinit(gpa);
        },
        .image_store => try program_image.write(&inputs.program, &inputs.out.writer),
        .story_init => {
            var story: Story = undefined;
            try story.init(gpa, &inputs.program, .{});
            story.deinit(gpa);
        },
        .play => try play_once(&inputs.played, iteration + 1),
        .save => try save.to_json(&inputs.played, &inputs.out.writer),
        .load_save => try load.load_json(&inputs.loader, inputs.save_json),
    }
    assert(inputs.out.written().len <= std.math.maxInt(u32));
}

fn now_ns(io: std.Io) u64 {
    const nanoseconds = std.Io.Timestamp.now(io, .awake).toNanoseconds();
    assert(nanoseconds >= 0);
    assert(nanoseconds < std.math.maxInt(u64));
    return @intCast(nanoseconds);
}

/// Runs `workload` for the time budget; returns the iterations and the wall time.
fn time_workload(io: std.Io, inputs: *Inputs, workload: Workload) !struct { u32, u64 } {
    assert(inputs.image.len > 0);
    // `save` measures the played story; play it to its end again first.
    if (workload == .save) try play_once(&inputs.played, 1);
    try run_once(inputs, workload, 0);
    profile.reset();
    const start = now_ns(io);
    var iterations: u32 = 0;
    while (iterations < iterations_max and
        (iterations < iterations_min or now_ns(io) - start < budget_nanoseconds))
    {
        try run_once(inputs, workload, iterations);
        iterations += 1;
    }
    assert(iterations >= iterations_min);
    return .{ iterations, now_ns(io) - start };
}

fn measure(io: std.Io, inputs: *Inputs, workload: Workload) !Measurement {
    assert(!profile.active);
    const plain_iterations, const plain_ns = try time_workload(io, inputs, workload);
    profile.active = true;
    const iterations, const wall_ns = try time_workload(io, inputs, workload);
    profile.active = false;
    const plain: f64 = @floatFromInt(plain_ns);
    const measurement: Measurement = .{
        .workload = workload,
        .iterations = iterations,
        .wall_ns = wall_ns,
        .totals = profile.totals(),
        .plain_ns_per_iteration = plain / @as(f64, @floatFromInt(plain_iterations)),
    };
    assert(measurement.wall_ns > 0);
    return measurement;
}

/// The records of a measurement: each zone it entered, then the time outside zones.
pub fn records_of(
    arena: Allocator,
    run: bench_io.Run,
    story: []const u8,
    measurement: *const Measurement,
) ![]Record {
    assert(measurement.iterations > 0);
    assert(measurement.wall_ns > 0);
    var records: std.ArrayList(Record) = .empty;
    const iterations: f64 = @floatFromInt(measurement.iterations);
    const wall: f64 = @floatFromInt(measurement.wall_ns);
    const base: Record = .{
        .timestamp = run.timestamp,
        .commit = run.commit,
        .dirty = run.dirty,
        .zig = run.zig,
        .mode = run.mode,
        .target = run.target,
        .cpu = run.cpu,
        .story = story,
        .workload = measurement.workload,
        .zone = "(outside zones)",
        .iterations = measurement.iterations,
        .wall_ns_per_iteration = wall / iterations,
        .plain_wall_ns_per_iteration = measurement.plain_ns_per_iteration,
        .calls_per_iteration = 0,
        .exclusive_ns_per_iteration = 0,
        .inclusive_ns_per_iteration = 0,
        .share = 0,
    };
    var zoned: u64 = 0;
    const totals = &measurement.totals;
    for (0..profile.zones_count) |zone| {
        if (totals.calls[zone] == 0) continue;
        zoned += totals.exclusive_ns[zone];
        const exclusive: f64 = @floatFromInt(totals.exclusive_ns[zone]);
        var record = base;
        record.zone = @tagName(@as(profile.Zone, @enumFromInt(zone)));
        record.calls_per_iteration = @as(f64, @floatFromInt(totals.calls[zone])) / iterations;
        record.exclusive_ns_per_iteration = exclusive / iterations;
        const inclusive: f64 = @floatFromInt(totals.inclusive_ns[zone]);
        record.inclusive_ns_per_iteration = inclusive / iterations;
        record.share = exclusive / wall;
        try records.append(arena, record);
    }
    std.mem.sort(Record, records.items, {}, by_exclusive_time);
    var outside = base;
    const outside_ns: f64 = @floatFromInt(measurement.wall_ns -| zoned);
    outside.exclusive_ns_per_iteration = outside_ns / iterations;
    outside.inclusive_ns_per_iteration = outside.exclusive_ns_per_iteration;
    outside.share = outside_ns / wall;
    try records.append(arena, outside);
    return records.items;
}

fn by_exclusive_time(_: void, a: Record, b: Record) bool {
    assert(a.iterations > 0);
    assert(b.iterations > 0);
    return a.exclusive_ns_per_iteration > b.exclusive_ns_per_iteration;
}

fn print_measurement(
    story: []const u8,
    measurement: *const Measurement,
    records: []const Record,
) void {
    assert(records.len > 0);
    assert(measurement.iterations > 0);
    const wall = @as(f64, @floatFromInt(measurement.wall_ns)) /
        @as(f64, @floatFromInt(measurement.iterations)) / 1e3;
    const plain = measurement.plain_ns_per_iteration / 1e3;
    const overhead = (wall / plain - 1) * 100;
    const sign = if (overhead >= 0) "+" else "";
    std.debug.print("\n{s} / {t}: {d} iterations, {d:.1} µs each with zones, {d:.1} µs " ++
        "without ({s}{d:.0}%)\n", .{
        story, measurement.workload, measurement.iterations, wall, plain, sign, overhead,
    });
    std.debug.print("  {s:<26} {s:>14} {s:>7} {s:>14} {s:>10}\n", .{
        "zone", "exclusive µs", "share", "inclusive µs", "calls",
    });
    for (records) |record| {
        std.debug.print("  {s:<26} {d:>14.2} {d:>6.1}% {d:>14.2} {d:>10.1}\n", .{
            record.zone,
            record.exclusive_ns_per_iteration / 1e3,
            record.share * 100,
            record.inclusive_ns_per_iteration / 1e3,
            record.calls_per_iteration,
        });
    }
}

/// One pass through the pipeline: a compile, a JSON load, a story init, one play, a save
/// and a load of it. The zones ranked by exclusive time over that pass.
fn print_contenders(arena: Allocator, story: []const u8, records: []const Record) !void {
    assert(records.len > 0);
    assert(story.len > 0);
    const pass = [_]Workload{ .compile, .json_load, .story_init, .play, .save, .load_save };
    var ranked: std.ArrayList(Record) = .empty;
    var total: f64 = 0;
    for (records) |record| {
        if (std.mem.indexOfScalar(Workload, &pass, record.workload) == null) continue;
        try ranked.append(arena, record);
        total += record.exclusive_ns_per_iteration;
    }
    std.mem.sort(Record, ranked.items, {}, by_exclusive_time);
    std.debug.print("\n{s}: worst zones of one pass (compile, JSON load, init, play, " ++
        "save, load save), {d:.1} µs in all\n", .{ story, total / 1e3 });
    for (ranked.items[0..@min(contenders_shown, ranked.items.len)], 1..) |record, rank| {
        std.debug.print("  {d:>2}. {s:<26} {t:<11} {d:>12.1} µs {d:>6.1}%\n", .{
            rank,
            record.zone,
            record.workload,
            record.exclusive_ns_per_iteration / 1e3,
            record.exclusive_ns_per_iteration / total * 100,
        });
    }
}

fn profile_story(
    gpa: Allocator,
    arena: Allocator,
    io: std.Io,
    run: bench_io.Run,
    subject: Subject,
    lines: *std.Io.Writer,
) !void {
    assert(subject.name.len > 0);
    const cwd = std.Io.Dir.cwd();
    const limit: std.Io.Limit = .limited(1 << 26);
    const source = try cwd.readFileAlloc(io, subject.source_path, arena, limit);
    const json = try cwd.readFileAlloc(io, subject.json_path, arena, limit);
    var inputs: Inputs = undefined;
    try inputs.prepare(gpa, source, json);
    defer inputs.deinit();
    var story_records: std.ArrayList(Record) = .empty;
    for (std.enums.values(Workload)) |workload| {
        const measurement = try measure(io, &inputs, workload);
        const records = try records_of(arena, run, subject.name, &measurement);
        print_measurement(subject.name, &measurement, records);
        for (records) |record| {
            try std.json.Stringify.value(record, .{}, lines);
            try lines.writeByte('\n');
        }
        try story_records.appendSlice(arena, records);
    }
    try print_contenders(arena, subject.name, story_records.items);
}

pub fn main(init: std.process.Init) !void {
    comptime assert(profile.enabled);
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    profile.start(io, 50_000_000);
    const run = try bench_io.run_info(arena, io);
    const dirty = if (run.dirty) " (dirty)" else "";
    std.debug.print("{s} {s}{s}, {s}\n", .{ run.mode, run.commit, dirty, run.cpu });
    var lines: std.Io.Writer.Allocating = .init(arena);
    for (subjects) |subject| try profile_story(gpa, arena, io, run, subject, &lines.writer);
    try bench_io.append_results(arena, io, results_path, lines.written());
    assert(builtin.mode != .debug);
}
