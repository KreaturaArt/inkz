//! The benchmarks, one program with a subcommand per kind, over one table of workloads
//! (`Workload`), on crime_scene and on the generated 1000-knot story (test/fixture/bench/),
//! in the build mode it was built with:
//!
//! - `bench runtime` (`zig build bench`): load time, play throughput, memory per instruction,
//!   compile time and peak memory; rewrites this mode's sections of docs/benchmarks.md
//!   (between its markers). The runtime plays ink's JSON with seeded choices, as the first
//!   baseline played the old runtime, so turns/s and lines/s compare with it.
//! - `bench io` (`zig build bench-io`): loading and storing a Program as ink's JSON and as
//!   the binary image; one record per story and measurement.
//! - `bench profile` (`zig build bench-profile`, built from src/bench_profile.zig, which
//!   compiles the profile zones in): every workload with the zones off, then on; one record
//!   per story, workload and zone, then the worst zones of one pass through the pipeline.
//!
//! `io` and `profile` print their records and append them as JSON Lines to
//! `zig-out/bench/<file>`, or with `--record` (`-Dbench-record`) to `bench/<file>`, the
//! committed history that docs/benchmarks.md cites.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const support = @import("testing/support.zig");
const compiler = @import("compiler/compile.zig");
const profile = @import("core/profile.zig");
const CountingAllocator = @import("core/counting_allocator.zig").CountingAllocator;
const ink_json = @import("core/ink_json.zig");
const program_image = @import("core/program_image.zig");
const limits_module = @import("core/limits.zig");
const Limits = limits_module.Limits;
const Program = @import("core/program.zig").Program;
const api = @import("runtime/story.zig");
const State = @import("runtime/state.zig").State;
const DotnetRandom = @import("core/dotnet_random.zig").DotnetRandom;

const Allocator = std.mem.Allocator;
const report_path = "docs/benchmarks.md";
const read_limit: std.Io.Limit = .limited(1 << 26);

pub const Command = enum { runtime, io, profile };

pub const Arguments = struct {
    command: Command,
    /// Append the records to the committed history in `bench/` instead of `zig-out/bench/`.
    record: bool,

    pub const usage = "usage: bench runtime | bench io [--record] | bench profile [--record]";

    pub fn parse(arguments: []const []const u8) error{BadArguments}!Arguments {
        if (arguments.len == 0 or arguments.len > 2) return error.BadArguments;
        const command = std.meta.stringToEnum(Command, arguments[0]) orelse {
            return error.BadArguments;
        };
        const record = arguments.len == 2;
        if (record and (command == .runtime or !std.mem.eql(u8, arguments[1], "--record"))) {
            return error.BadArguments;
        }
        return .{ .command = command, .record = record };
    }

    /// The path of the results file `file_name` (`profile.jsonl`, `load_store.jsonl`).
    pub fn path(arguments: Arguments, arena: Allocator, file_name: []const u8) ![]const u8 {
        assert(arguments.command != .runtime);
        assert(std.mem.indexOfScalar(u8, file_name, '/') == null);
        const directory = if (arguments.record) "bench" else "zig-out/bench";
        return std.fmt.allocPrint(arena, "{s}/{s}", .{ directory, file_name });
    }
};

const Subject = struct {
    /// The name in the records, and the one in docs/benchmarks.md's tables.
    name: []const u8,
    title: []const u8,
    source_path: []const u8,
    json_path: []const u8,
};
const subjects = [_]Subject{
    .{
        .name = "crime_scene",
        .title = "crime_scene",
        .source_path = "test/fixture/crime_scene.ink",
        .json_path = "test/ground_truth/crime_scene.ink.json",
    },
    .{
        .name = "generated_1000_knots",
        .title = "generated (1000 knots)",
        .source_path = "test/fixture/bench/generated.ink",
        .json_path = "test/fixture/bench/generated.ink.json",
    },
};

/// Everything the benchmarks time. A sample times one run of a workload, with freeing what
/// it made, except for the program loads (`io` times the load alone).
pub const Workload = enum {
    /// Source to Program.
    compile,
    /// Source to ink's JSON (`runtime`'s compile).
    compile_json,
    json_load,
    json_store,
    image_load,
    /// The image through `program_image.load_trusted`.
    image_load_trusted,
    image_store,
    story_init,
    /// Program and story from ink's JSON, and from the image (`runtime`'s load).
    json_open,
    image_open,
    /// One seeded play from the start (seed: the sample's number + 1).
    play,
    save,
    load_save,

    /// Each `io` workload is a format and an operation, as bench/load_store.jsonl names them.
    pub const io = [_]Workload{
        .json_load, .json_store, .image_load, .image_store, .image_load_trusted,
    };
    pub const profiled = [_]Workload{
        .compile,    .json_load, .json_store, .image_load, .image_store,
        .story_init, .play,      .save,       .load_save,
    };
    /// One pass through the pipeline, for the profile's worst zones.
    pub const pass = [_]Workload{ .compile, .json_load, .story_init, .play, .save, .load_save };

    pub fn io_format(workload: Workload) Format {
        return switch (workload) {
            .json_load, .json_store => .json,
            .image_load, .image_store => .image,
            .image_load_trusted => .image_trusted,
            else => unreachable,
        };
    }

    pub fn io_operation(workload: Workload) Operation {
        return switch (workload) {
            .json_load, .image_load, .image_load_trusted => .load,
            .json_store, .image_store => .store,
            else => unreachable,
        };
    }
};

pub const Format = enum { json, image, image_trusted };
pub const Operation = enum { load, store };

/// What the workloads of one story run on.
pub const Inputs = struct {
    gpa: Allocator,
    io: std.Io,
    source: []const u8,
    json: []const u8,
    limits: Limits,
    program: Program,
    image: []u8,
    /// This runtime's JSON of the program.
    json_written: []u8,
    out: std.Io.Writer.Allocating,
    /// Played to its end once, for `save`; `loader` loads its save.
    played: api.Story,
    loader: api.Story,
    save_json: []u8,
    /// What `play` has played since `prepare`.
    turns: u64 = 0,
    lines: u64 = 0,

    /// Makes the inputs, and checks that both formats round-trip: what a load reads, a store
    /// writes back the same.
    pub fn prepare(
        inputs: *Inputs,
        gpa: Allocator,
        io: std.Io,
        source: []const u8,
        json: []const u8,
        limits: Limits,
    ) !void {
        inputs.* = .{
            .gpa = gpa,
            .io = io,
            .source = source,
            .json = json,
            .limits = limits,
            .program = try ink_json.load(gpa, json),
            .image = &.{},
            .json_written = &.{},
            .out = .init(gpa),
            .played = undefined,
            .loader = undefined,
            .save_json = &.{},
        };
        try program_image.write(&inputs.program, &inputs.out.writer);
        inputs.image = try gpa.dupe(u8, inputs.out.written());
        assert(inputs.image.len == program_image.image_bytes(&inputs.program));
        inputs.out.clearRetainingCapacity();
        try ink_json.serialize(gpa, &inputs.program, &inputs.out.writer);
        inputs.json_written = try gpa.dupe(u8, inputs.out.written());
        const options: api.Story.Options = .{
            .limits = limits,
            .on_error = support.ignore_message,
        };
        try inputs.played.init(gpa, &inputs.program, options);
        try inputs.loader.init(gpa, &inputs.program, options);
        _ = try play(&inputs.played, 1);
        inputs.out.clearRetainingCapacity();
        try inputs.played.to_json(&inputs.out.writer);
        inputs.save_json = try gpa.dupe(u8, inputs.out.written());
        try inputs.check_round_trips();
    }

    pub fn deinit(inputs: *Inputs) void {
        const gpa = inputs.gpa;
        inputs.loader.deinit(gpa);
        inputs.played.deinit(gpa);
        gpa.free(inputs.save_json);
        gpa.free(inputs.json_written);
        gpa.free(inputs.image);
        inputs.out.deinit();
        inputs.program.deinit(gpa);
        inputs.* = undefined;
    }

    fn check_round_trips(inputs: *Inputs) !void {
        const gpa = inputs.gpa;
        assert(inputs.program.check() == .ok);
        var from_image = try program_image.load(gpa, inputs.image);
        defer from_image.deinit(gpa);
        inputs.out.clearRetainingCapacity();
        try program_image.write(&from_image, &inputs.out.writer);
        if (!std.mem.eql(u8, inputs.out.written(), inputs.image)) return error.ImageRoundTrip;
        var from_json = try ink_json.load(gpa, inputs.json_written);
        defer from_json.deinit(gpa);
        inputs.out.clearRetainingCapacity();
        try ink_json.serialize(gpa, &from_json, &inputs.out.writer);
        if (!std.mem.eql(u8, inputs.out.written(), inputs.json_written)) {
            return error.JsonRoundTrip;
        }
    }

    /// Runs `workload` once; returns the nanoseconds it took.
    pub fn run(inputs: *Inputs, workload: Workload, iteration: u32) !u64 {
        const gpa = inputs.gpa;
        inputs.out.clearRetainingCapacity();
        const timer: Timer = .begin(inputs.io);
        switch (workload) {
            .compile => {
                var program = try compiler.compile_source(gpa, inputs.source);
                program.deinit(gpa);
            },
            .compile_json => gpa.free(try compiler.compile_to_json(gpa, inputs.source)),
            .json_load, .image_load, .image_load_trusted => {
                var program = switch (workload) {
                    .json_load => try ink_json.load(gpa, inputs.json),
                    .image_load => try program_image.load(gpa, inputs.image),
                    else => try program_image.load_trusted(gpa, inputs.image),
                };
                const elapsed = timer.nanoseconds(inputs.io);
                program.deinit(gpa);
                return elapsed;
            },
            .json_store => try ink_json.serialize(gpa, &inputs.program, &inputs.out.writer),
            .image_store => try program_image.write(&inputs.program, &inputs.out.writer),
            .story_init => {
                var story: api.Story = undefined;
                try story.init(gpa, &inputs.program, .{ .limits = inputs.limits });
                story.deinit(gpa);
            },
            .json_open, .image_open => {
                var program = if (workload == .json_open)
                    try ink_json.load(gpa, inputs.json)
                else
                    try program_image.load(gpa, inputs.image);
                defer program.deinit(gpa);
                var story: api.Story = undefined;
                try story.init(gpa, &program, .{ .limits = inputs.limits });
                story.deinit(gpa);
            },
            .play => {
                const played = try play(&inputs.played, iteration + 1);
                inputs.turns += played.turns;
                inputs.lines += played.lines;
            },
            .save => try inputs.played.to_json(&inputs.out.writer),
            .load_save => try inputs.loader.load_json(inputs.save_json),
        }
        return timer.nanoseconds(inputs.io);
    }
};

/// One play from the start, as the first baseline played the old runtime: every line, then
/// a choice by .NET Random seeded with `seed`, until there are no choices or
/// `support.turns_max` choices have been taken. Unlike `support.play`, the lines after the
/// last choice are not played.
fn play(story: *api.Story, seed: u32) !support.Played {
    assert(seed > 0);
    try story.reset_state();
    var random = DotnetRandom.init(@intCast(seed));
    var played: support.Played = .{};
    while (played.turns < support.turns_max) : (played.turns += 1) {
        while (story.can_continue()) : (played.lines += 1) _ = try story.cont();
        const count = story.current_choices_count();
        if (count == 0) break;
        try story.choose_choice_index(@intCast(@mod(random.next(), @as(i32, @intCast(count)))));
    }
    return played;
}

/// The awake clock since `begin`.
const Timer = struct {
    started: std.Io.Timestamp,

    fn begin(io: std.Io) Timer {
        return .{ .started = .now(io, .awake) };
    }

    fn nanoseconds(timer: Timer, io: std.Io) u64 {
        const elapsed = timer.started.durationTo(.now(io, .awake)).toNanoseconds();
        assert(elapsed >= 0);
        return @intCast(elapsed);
    }
};

/// How long `sample` keeps sampling: `warmup` untimed runs, then samples until there are
/// `samples_min` and either `budget_nanoseconds` of them or `samples_max`.
pub const Sampling = struct {
    warmup: u32 = 0,
    samples_min: u32,
    samples_max: u32,
    budget_nanoseconds: u64 = 0,

    const samples_capacity = 10_000;
    const load_store: Sampling = .{
        .warmup = 3,
        .samples_min = 10,
        .samples_max = 500,
        .budget_nanoseconds = 1_000_000_000,
    };
    const zones: Sampling = .{
        .samples_min = 3,
        .samples_max = samples_capacity,
        .budget_nanoseconds = 1_000_000_000,
    };

    fn exactly(count: u32) Sampling {
        return .{ .samples_min = count, .samples_max = count };
    }
};

/// Calls `once(context, iteration)` as `sampling` says; each call returns the nanoseconds
/// it timed. Returns the samples' statistics; `buffer` holds the samples.
pub fn sample(
    context: anytype,
    comptime once: fn (@TypeOf(context), u32) anyerror!u64,
    sampling: Sampling,
    buffer: []u64,
) !Stats {
    assert(sampling.samples_min > 0);
    assert(sampling.samples_min <= sampling.samples_max);
    assert(buffer.len >= sampling.samples_max);
    for (0..sampling.warmup) |iteration| _ = try once(context, @intCast(iteration));
    var count: u32 = 0;
    var total: u64 = 0;
    while (count < sampling.samples_max and
        (count < sampling.samples_min or total < sampling.budget_nanoseconds))
    {
        buffer[count] = try once(context, count);
        total += buffer[count];
        count += 1;
    }
    return stats_of(buffer[0..count]);
}

pub const Stats = struct { samples: u32, min: u64, median: u64, mean: u64, max: u64, total: u64 };

/// Sorts `samples` and returns their statistics.
pub fn stats_of(samples: []u64) Stats {
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    var total: u64 = 0;
    for (samples) |one| total += one;
    return .{
        .samples = @intCast(samples.len),
        .min = samples[0],
        .median = samples[samples.len / 2],
        .mean = total / samples.len,
        .max = samples[samples.len - 1],
        .total = total,
    };
}

/// `workload` on `inputs`, sampled as `sampling` says.
fn measure(inputs: *Inputs, workload: Workload, sampling: Sampling) !Stats {
    const Sampled = struct {
        inputs: *Inputs,
        workload: Workload,

        fn once(sampled: *const @This(), iteration: u32) !u64 {
            return sampled.inputs.run(sampled.workload, iteration);
        }
    };
    var buffer: [Sampling.samples_capacity]u64 = undefined;
    const sampled: Sampled = .{ .inputs = inputs, .workload = workload };
    return sample(&sampled, Sampled.once, sampling, &buffer);
}

// Records.

/// What a run's records share: when, which code, which build, which machine.
pub const Run = struct {
    timestamp: []const u8,
    commit: []const u8,
    dirty: bool,
    zig: []const u8,
    mode: []const u8,
    target: []const u8,
    cpu: []const u8,
};

/// What an `io` record adds to its run (bench/load_store.jsonl).
pub const LoadStore = struct {
    format: Format,
    operation: Operation,
    /// The size of the serialized program (the input of a load, the output of a store).
    bytes: u64,
    samples: u32,
    min_ns: u64,
    median_ns: u64,
    mean_ns: u64,
    max_ns: u64,
    /// `bytes` over the median time.
    megabytes_per_second: f64,
};

/// What a `profile` record adds to its run (bench/profile.jsonl): a zone of a workload, per
/// iteration.
pub const ZoneTime = struct {
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

/// Writes one record, a JSON line: the run's fields, `story`, then `fields`' fields.
pub fn write_record(
    lines: *std.Io.Writer,
    run: Run,
    story: []const u8,
    fields: anytype,
) !void {
    var json: std.json.Stringify = .{ .writer = lines };
    try json.beginObject();
    inline for (@typeInfo(Run).@"struct".field_names) |name| {
        try json.objectField(name);
        try json.write(@field(run, name));
    }
    try json.objectField("story");
    try json.write(story);
    inline for (@typeInfo(@TypeOf(fields)).@"struct".field_names) |name| {
        try json.objectField(name);
        try json.write(@field(fields, name));
    }
    try json.endObject();
    try lines.writeByte('\n');
}

/// The record of an `io` measurement: a load reads the input JSON (inklecate's) or the
/// image; a store writes this runtime's JSON or the image.
pub fn load_store_of(inputs: *const Inputs, workload: Workload, stats: Stats) LoadStore {
    const operation = workload.io_operation();
    const bytes: u64 = switch (workload.io_format()) {
        .json => if (operation == .load) inputs.json.len else inputs.json_written.len,
        .image, .image_trusted => inputs.image.len,
    };
    const seconds = @as(f64, @floatFromInt(stats.median)) / 1e9;
    return .{
        .format = workload.io_format(),
        .operation = operation,
        .bytes = bytes,
        .samples = stats.samples,
        .min_ns = stats.min,
        .median_ns = stats.median,
        .mean_ns = stats.mean,
        .max_ns = stats.max,
        .megabytes_per_second = @as(f64, @floatFromInt(bytes)) / 1e6 / seconds,
    };
}

/// One profiled workload: wall time and the zones' totals, over `iterations`, and the wall
/// time per iteration of the same workload with the zones off.
pub const Profiled = struct {
    workload: Workload,
    iterations: u32,
    wall_ns: u64,
    totals: profile.Totals,
    plain_ns_per_iteration: f64,
};

/// The records of a profiled workload: each zone it entered by exclusive time, then the
/// time outside zones.
pub fn zone_times_of(arena: Allocator, profiled: *const Profiled) ![]ZoneTime {
    assert(profiled.iterations > 0);
    assert(profiled.wall_ns > 0);
    var records: std.ArrayList(ZoneTime) = .empty;
    const iterations: f64 = @floatFromInt(profiled.iterations);
    const wall: f64 = @floatFromInt(profiled.wall_ns);
    const base: ZoneTime = .{
        .workload = profiled.workload,
        .zone = "(outside zones)",
        .iterations = profiled.iterations,
        .wall_ns_per_iteration = wall / iterations,
        .plain_wall_ns_per_iteration = profiled.plain_ns_per_iteration,
        .calls_per_iteration = 0,
        .exclusive_ns_per_iteration = 0,
        .inclusive_ns_per_iteration = 0,
        .share = 0,
    };
    var zoned: u64 = 0;
    const totals = &profiled.totals;
    for (0..profile.zones_count) |zone| {
        if (totals.calls[zone] == 0) continue;
        zoned += totals.exclusive_ns[zone];
        const exclusive: f64 = @floatFromInt(totals.exclusive_ns[zone]);
        const inclusive: f64 = @floatFromInt(totals.inclusive_ns[zone]);
        var record = base;
        record.zone = @tagName(@as(profile.Zone, @fromBackingInt(@intCast(zone))));
        record.calls_per_iteration = @as(f64, @floatFromInt(totals.calls[zone])) / iterations;
        record.exclusive_ns_per_iteration = exclusive / iterations;
        record.inclusive_ns_per_iteration = inclusive / iterations;
        record.share = exclusive / wall;
        try records.append(arena, record);
    }
    std.mem.sort(ZoneTime, records.items, {}, by_exclusive_time);
    var outside = base;
    const outside_ns: f64 = @floatFromInt(profiled.wall_ns -| zoned);
    outside.exclusive_ns_per_iteration = outside_ns / iterations;
    outside.inclusive_ns_per_iteration = outside.exclusive_ns_per_iteration;
    outside.share = outside_ns / wall;
    try records.append(arena, outside);
    return records.items;
}

fn by_exclusive_time(_: void, a: ZoneTime, b: ZoneTime) bool {
    return a.exclusive_ns_per_iteration > b.exclusive_ns_per_iteration;
}

/// Runs `git` in the working directory; null if it can't.
fn git(arena: Allocator, io: std.Io, argv: []const []const u8) ?[]const u8 {
    const result = std.process.run(arena, io, .{ .argv = argv }) catch return null;
    if (result.term != .exited or result.term.exited != 0) return null;
    return std.mem.trim(u8, result.stdout, " \n");
}

fn run_info(arena: Allocator, io: std.Io) !Run {
    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(now) };
    const day = epoch.getEpochDay().calculateYearDay();
    const month = day.calculateMonthDay();
    const time = epoch.getDaySeconds();
    const format = "{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z";
    const timestamp = try std.fmt.allocPrint(arena, format, .{
        day.year,
        month.month.numeric(),
        month.day_index + 1,
        time.getHoursIntoDay(),
        time.getMinutesIntoHour(),
        time.getSecondsIntoMinute(),
    });
    const commit = git(arena, io, &.{ "git", "rev-parse", "--short=12", "HEAD" });
    const status_argv = [_][]const u8{ "git", "status", "--porcelain", "--untracked-files=no" };
    const status: []const u8 = git(arena, io, &status_argv) orelse "";
    return .{
        .timestamp = timestamp,
        .commit = commit orelse "unknown",
        .dirty = status.len > 0,
        .zig = builtin.zig_version_string,
        .mode = @tagName(builtin.mode),
        .target = try std.fmt.allocPrint(arena, "{t}-{t}", .{ builtin.cpu.arch, builtin.os.tag }),
        .cpu = builtin.cpu.model.name,
    };
}

/// Appends `lines` to the results file at `path`, creating it (and its directory) if needed.
fn append_results(arena: Allocator, io: std.Io, path: []const u8, lines: []const u8) !void {
    assert(lines.len > 0 and lines[lines.len - 1] == '\n');
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, std.fs.path.dirname(path).?);
    const existing = cwd.readFileAlloc(io, path, arena, read_limit) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    const text = try std.mem.concat(arena, u8, &.{ existing, lines });
    try cwd.writeFile(io, .{ .sub_path = path, .data = text });
    const count = std.mem.count(u8, lines, "\n");
    std.debug.print("appended {d} records to {s}\n", .{ count, path });
}

/// `report` with the section `name` (between its markers for this build mode) replaced by
/// `body` under a heading `title`, or appended when the report has no such section.
pub fn replace_section(
    arena: Allocator,
    report: []const u8,
    name: []const u8,
    title: []const u8,
    body: []const u8,
) ![]const u8 {
    const mode = builtin.mode;
    const start_marker = try std.fmt.allocPrint(arena, "<!-- {s}:{t}:start -->", .{ name, mode });
    const end_marker = try std.fmt.allocPrint(arena, "<!-- {s}:{t}:end -->", .{ name, mode });
    const section = try std.fmt.allocPrint(arena, "{s}\n### {s}, {t}\n\n{s}{s}\n", .{
        start_marker, title, mode, body, end_marker,
    });
    const start = std.mem.indexOf(u8, report, start_marker);
    const end = std.mem.indexOf(u8, report, end_marker);
    if (start == null or end == null) return std.mem.concat(arena, u8, &.{ report, "\n", section });
    return std.mem.concat(arena, u8, &.{
        report[0..start.?],
        section,
        report[end.? + end_marker.len + 1 ..],
    });
}

// The subcommands.

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    assert(argv.len >= 1);
    const arguments = Arguments.parse(argv[1..]) catch |err| {
        std.debug.print("{s}\n", .{Arguments.usage});
        return err;
    };
    if (arguments.command == .profile and !profile.enabled) {
        std.debug.print("bench profile needs the zones: zig build bench-profile\n", .{});
        return error.ProfileNotCompiledIn;
    }
    const run = try run_info(arena, init.io);
    const dirty = if (run.dirty) " (dirty)" else "";
    std.debug.print("{s} {s}{s}, {s}\n", .{ run.mode, run.commit, dirty, run.cpu });
    if (profile.enabled and arguments.command == .profile) profile.start(init.io, 50_000_000);
    var lines: std.Io.Writer.Allocating = .init(arena);
    var runtime_rows: std.Io.Writer.Allocating = .init(arena);
    var compiler_rows: std.Io.Writer.Allocating = .init(arena);
    for (subjects) |subject| {
        const cwd = std.Io.Dir.cwd();
        const source = try cwd.readFileAlloc(init.io, subject.source_path, arena, read_limit);
        const json = try cwd.readFileAlloc(init.io, subject.json_path, arena, read_limit);
        var inputs: Inputs = undefined;
        try inputs.prepare(init.gpa, init.io, source, json, .{});
        defer inputs.deinit();
        switch (arguments.command) {
            .runtime => {
                try runtime_story(arena, &inputs, subject.title, false, &runtime_rows.writer);
                try runtime_story(arena, &inputs, subject.title, true, &runtime_rows.writer);
                try compiler_story(&inputs, subject.title, &compiler_rows.writer);
            },
            .io => try io_story(&inputs, run, subject.name, &lines.writer),
            .profile => {
                if (!profile.enabled) unreachable;
                try profile_story(arena, &inputs, run, subject.name, &lines.writer);
            },
        }
    }
    if (arguments.command == .runtime) {
        try write_runtime_report(arena, init.io, runtime_rows.written(), compiler_rows.written());
    } else {
        const file = if (arguments.command == .io) "load_store.jsonl" else "profile.jsonl";
        try append_results(arena, init.io, try arguments.path(arena, file), lines.written());
    }
}

const runtime_counts = struct {
    const loads = 200;
    const plays = 200;
    const compiles = 20;
};

/// A `runtime` table row: load (program and story) from the JSON and from the image, play,
/// and memory (the program plus the state's fixed budget). `fit` plays with limits fitted
/// to the bench's own play (margin 2) instead of the defaults.
fn runtime_story(
    arena: Allocator,
    default_inputs: *Inputs,
    title: []const u8,
    fit: bool,
    rows: *std.Io.Writer,
) !void {
    const gpa = default_inputs.gpa;
    var counting = CountingAllocator.init(gpa);
    var program = try ink_json.load(counting.allocator(), default_inputs.json);
    const program_bytes = counting.bytes_live;
    program.deinit(counting.allocator());
    var fitted: Inputs = undefined;
    const inputs = if (fit) blk: {
        _ = try measure(default_inputs, .play, .exactly(runtime_counts.plays));
        const limits = limits_module.fitted(default_inputs.played.usage(), 2);
        const io = default_inputs.io;
        try fitted.prepare(gpa, io, default_inputs.source, default_inputs.json, limits);
        break :blk &fitted;
    } else default_inputs;
    defer if (fit) fitted.deinit();
    const loads: Sampling = .exactly(runtime_counts.loads);
    const json_open = try measure(inputs, .json_open, loads);
    const image_open = try measure(inputs, .image_open, loads);
    inputs.turns = 0;
    inputs.lines = 0;
    const steps_before = inputs.played.steps_total;
    const plays = try measure(inputs, .play, .exactly(runtime_counts.plays));
    const seconds = @as(f64, @floatFromInt(plays.total)) / 1e9;
    const steps = inputs.played.steps_total - steps_before;
    const state_bytes = inputs.limits.bytes_total(State.shape_of(&inputs.program));
    const loaded_bytes = program_bytes + state_bytes;
    const instructions = inputs.program.instructions_count();
    const name = if (fit) try std.fmt.allocPrint(arena, "{s}, fitted limits", .{title}) else title;
    try rows.print("| {s} | {d:.1} | {d:.1} | {d:.0} | {d:.0} | {d:.0} | {d} | {d} | {d} " ++
        "| {d:.1} |\n", .{
        name,
        @as(f64, @floatFromInt(json_open.total)) / runtime_counts.loads / 1e3,
        @as(f64, @floatFromInt(image_open.total)) / runtime_counts.loads / 1e3,
        @as(f64, @floatFromInt(inputs.turns)) / seconds,
        @as(f64, @floatFromInt(inputs.lines)) / seconds,
        @as(f64, @floatFromInt(steps)) / seconds,
        loaded_bytes,
        inputs.image.len,
        instructions,
        @as(f64, @floatFromInt(loaded_bytes)) / @as(f64, @floatFromInt(instructions)),
    });
}

/// A `runtime` compiler row: source to JSON, the mean time and the peak bytes, and the
/// whole re-parses because the workspace estimate was too small (F14: kept at 0).
fn compiler_story(inputs: *Inputs, title: []const u8, rows: *std.Io.Writer) !void {
    const gpa = inputs.gpa;
    const compile = try measure(inputs, .compile_json, .exactly(runtime_counts.compiles));
    var counting = CountingAllocator.init(gpa);
    counting.allocator().free(try compiler.compile_to_json(counting.allocator(), inputs.source));
    assert(counting.bytes_live == 0);
    var statistics: compiler.Statistics = .{};
    var program = try compiler.compile_source_with(gpa, inputs.source, .{
        .statistics = &statistics,
    });
    program.deinit(gpa);
    try rows.print("| {s} | {d:.2} | {d} | {d} |\n", .{
        title,
        @as(f64, @floatFromInt(compile.total)) / runtime_counts.compiles / 1e6,
        counting.bytes_peak,
        statistics.workspace_retries,
    });
}

fn write_runtime_report(
    arena: Allocator,
    io: std.Io,
    runtime_rows: []const u8,
    compiler_rows: []const u8,
) !void {
    const cwd = std.Io.Dir.cwd();
    var report = cwd.readFileAlloc(io, report_path, arena, .limited(1 << 22)) catch "";
    report = try replace_section(arena, report, "bench-runtime", "Runtime", try std.mem.concat(
        arena,
        u8,
        &.{
            "| Story | Load (µs) | Image load (µs) | Turns/s | Lines/s | Instructions/s | " ++
                "Bytes (program + state) | Image bytes | Instructions | Bytes/instruction |\n" ++
                "|---|---|---|---|---|---|---|---|---|---|\n",
            runtime_rows,
            "\nThe state is the limits' fixed budget, allocated once: the defaults, or limits " ++
                "fitted to the bench's own play with margin 2.\n",
        },
    ));
    report = try replace_section(arena, report, "bench-compile", "Compiler", try std.fmt.allocPrint(
        arena,
        "| Story | Compile (ms) | Peak bytes | Workspace retries |\n|---|---|---|---|\n{s}" ++
            "\nSource to JSON; the time is the mean of {d} compiles.\n",
        .{ compiler_rows, runtime_counts.compiles },
    ));
    try cwd.writeFile(io, .{ .sub_path = report_path, .data = report });
}

fn io_story(inputs: *Inputs, run: Run, story: []const u8, lines: *std.Io.Writer) !void {
    try inputs.out.ensureTotalCapacity(@max(inputs.json_written.len, inputs.image.len));
    std.debug.print("{s:<22} {s:<13} {s:<6} {s:>10} {s:>12} {s:>10}\n", .{
        "story", "format", "op", "bytes",
        "median µs",
        "MB/s",
    });
    for (Workload.io) |workload| {
        const record = load_store_of(inputs, workload, try measure(inputs, workload, .load_store));
        try write_record(lines, run, story, record);
        std.debug.print("{s:<22} {t:<13} {t:<6} {d:>10} {d:>12.1} {d:>10.1}\n", .{
            story,
            record.format,
            record.operation,
            record.bytes,
            @as(f64, @floatFromInt(record.median_ns)) / 1e3,
            record.megabytes_per_second,
        });
    }
}

/// Runs `workload` for the profile's time budget; returns the iterations and the wall time.
fn time_workload(inputs: *Inputs, workload: Workload) !struct { u32, u64 } {
    // `save` measures the played story; play it to its end again first.
    if (workload == .save) _ = try inputs.run(.play, 0);
    _ = try inputs.run(workload, 0);
    profile.reset();
    const stats = try measure(inputs, workload, .zones);
    return .{ stats.samples, stats.total };
}

fn profile_story(
    arena: Allocator,
    inputs: *Inputs,
    run: Run,
    story: []const u8,
    lines: *std.Io.Writer,
) !void {
    var story_records: std.ArrayList(ZoneTime) = .empty;
    for (Workload.profiled) |workload| {
        assert(!profile.active);
        const plain_iterations, const plain_ns = try time_workload(inputs, workload);
        profile.active = true;
        const iterations, const wall_ns = try time_workload(inputs, workload);
        profile.active = false;
        const profiled: Profiled = .{
            .workload = workload,
            .iterations = iterations,
            .wall_ns = wall_ns,
            .totals = profile.totals(),
            .plain_ns_per_iteration = @as(f64, @floatFromInt(plain_ns)) /
                @as(f64, @floatFromInt(plain_iterations)),
        };
        const records = try zone_times_of(arena, &profiled);
        const wall = @as(f64, @floatFromInt(wall_ns)) / @as(f64, @floatFromInt(iterations)) / 1e3;
        const plain = profiled.plain_ns_per_iteration / 1e3;
        const overhead = (wall / plain - 1) * 100;
        std.debug.print("\n{s} / {t}: {d} iterations, {d:.1} µs each with zones, {d:.1} µs " ++
            "without ({d:.0}%)\n", .{ story, workload, iterations, wall, plain, overhead });
        std.debug.print("  {s:<26} {s:>14} {s:>7} {s:>14} {s:>10}\n", .{
            "zone",
            "exclusive µs",
            "share",
            "inclusive µs",
            "calls",
        });
        for (records) |record| {
            try write_record(lines, run, story, record);
            std.debug.print("  {s:<26} {d:>14.2} {d:>6.1}% {d:>14.2} {d:>10.1}\n", .{
                record.zone,
                record.exclusive_ns_per_iteration / 1e3,
                record.share * 100,
                record.inclusive_ns_per_iteration / 1e3,
                record.calls_per_iteration,
            });
        }
        try story_records.appendSlice(arena, records);
    }
    // The zones of one pass through the pipeline, ranked by exclusive time.
    var ranked: std.ArrayList(ZoneTime) = .empty;
    var total: f64 = 0;
    for (story_records.items) |record| {
        if (std.mem.indexOfScalar(Workload, &Workload.pass, record.workload) == null) continue;
        try ranked.append(arena, record);
        total += record.exclusive_ns_per_iteration;
    }
    std.mem.sort(ZoneTime, ranked.items, {}, by_exclusive_time);
    std.debug.print("\n{s}: worst zones of one pass (compile, JSON load, init, play, " ++
        "save, load save), {d:.1} µs in all\n", .{ story, total / 1e3 });
    for (ranked.items[0..@min(12, ranked.items.len)], 1..) |record, rank| {
        std.debug.print("  {d:>2}. {s:<26} {t:<11} {d:>12.1} µs {d:>6.1}%\n", .{
            rank,
            record.zone,
            record.workload,
            record.exclusive_ns_per_iteration / 1e3,
            record.exclusive_ns_per_iteration / total * 100,
        });
    }
}
