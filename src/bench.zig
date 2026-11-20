//! `zig build bench`: the runtime and the compiler, in the build mode it was built with.
//! Measures load time, play throughput, memory per instruction, compile time and peak memory
//! on crime_scene and on a generated large story, and rewrites this mode's sections of
//! docs/benchmarks.md (between its markers).
//!
//! The runtime plays ink's JSON of the stories (test/ground_truth/crime_scene.ink.json,
//! test/fixture/bench/generated.ink.json) with seeded choices, as the first baseline played the
//! old runtime, so turns/s and lines/s compare with it; the baseline sections are kept as they
//! were measured.

const std = @import("std");
const builtin = @import("builtin");
const common = @import("bench_common.zig");
const support = @import("testing/support.zig");
const compiler = @import("compiler/compile.zig");
const CountingAllocator = @import("core/counting_allocator.zig").CountingAllocator;
const ink_json = @import("core/ink_json.zig");
const program_image = @import("core/program_image.zig");
const limits_module = @import("core/limits.zig");
const Limits = limits_module.Limits;
const Program = @import("core/program.zig").Program;
const Story = @import("runtime/story.zig").Story;
const State = @import("runtime/state.zig").State;

const Allocator = std.mem.Allocator;
const report_path = "docs/benchmarks.md";
const loads_count = 200;
const plays_count = 200;
const compiles_count = 20;
const generated_knots_count = 1000;

const Measurement = struct {
    name: []const u8,
    load_microseconds: f64,
    /// The same load from the binary program image, and the image's size.
    image_load_microseconds: f64,
    image_bytes: u64,
    play_turns_per_second: f64,
    play_lines_per_second: f64,
    play_steps_per_second: f64,
    loaded_bytes: u64,
    instructions_count: u64,
};

const CompilerMeasurement = struct {
    name: []const u8,
    milliseconds: f64,
    peak_bytes: u64,
};

/// `count` runs of `once`, back to back; returns the mean nanoseconds.
fn mean_nanoseconds(
    context: anytype,
    comptime once: fn (@TypeOf(context), u32) anyerror!u64,
    comptime count: u32,
) !f64 {
    var buffer: [count]u64 = undefined;
    const sampling: common.Sampling = .{ .samples_min = count, .samples_max = count };
    const stats = common.stats_of(try common.sample(context, once, sampling, &buffer));
    return @as(f64, @floatFromInt(stats.total)) / count;
}

/// Compiles `source` to JSON, timed.
const Compile = struct {
    gpa: Allocator,
    io: std.Io,
    source: []const u8,

    fn once(compile: *const Compile, iteration: u32) !u64 {
        _ = iteration;
        const timer: common.Timer = .begin(compile.io);
        compile.gpa.free(try compiler.compile_to_json(compile.gpa, compile.source));
        return timer.nanoseconds(compile.io);
    }
};

/// The compiler from source to JSON: mean time over `compiles_count` runs, and peak bytes.
fn measure_compiler(
    gpa: Allocator,
    io: std.Io,
    name: []const u8,
    source: []const u8,
) !CompilerMeasurement {
    const compile: Compile = .{ .gpa = gpa, .io = io, .source = source };
    const nanoseconds = try mean_nanoseconds(&compile, Compile.once, compiles_count);
    var counting = CountingAllocator.init(gpa);
    counting.allocator().free(try compiler.compile_to_json(counting.allocator(), source));
    std.debug.assert(counting.bytes_live == 0);
    return .{ .name = name, .milliseconds = nanoseconds / 1e6, .peak_bytes = counting.bytes_peak };
}

/// A large story: `generated_knots_count` knots, each with text, a variable update and two
/// choices that divert onwards, so play visits many containers.
fn generate_story(gpa: Allocator) ![]u8 {
    var source: std.Io.Writer.Allocating = .init(gpa);
    errdefer source.deinit();
    const writer = &source.writer;
    try writer.writeAll("VAR score = 0\n-> knot_0\n");
    for (0..generated_knots_count) |index| {
        const next = (index + 1) % generated_knots_count;
        const skip = (index + 7) % generated_knots_count;
        try writer.print(
            "=== knot_{d} ===\nYou are in room {d}. Score {{score}}.\n~ score = score + {d}\n" ++
                "* [Onwards] -> knot_{d}\n* [Skip ahead] Skipping. -> knot_{d}\n",
            .{ index, index, index % 5, next, skip },
        );
    }
    return source.toOwnedSlice();
}

const PlayRate = struct { turns: f64, lines: f64, steps: f64, usage: limits_module.Usage };

/// Plays `plays_count` times with the baseline's seeded choices (seeds 1, 2, ...).
fn measure_play(gpa: Allocator, io: std.Io, program: *const Program, limits: Limits) !PlayRate {
    var story: Story = undefined;
    try story.init(gpa, program, limits);
    defer story.deinit(gpa);
    story.on_error = support.ignore_message;
    var turns: u64 = 0;
    var lines: u64 = 0;
    const steps_before = story.steps_total;
    const timer: common.Timer = .begin(io);
    for (1..plays_count + 1) |seed| {
        const played = try common.play(&story, @intCast(seed));
        turns += played.turns;
        lines += played.lines;
    }
    const seconds = @as(f64, @floatFromInt(timer.nanoseconds(io))) / 1e9;
    const steps = story.steps_total - steps_before;
    return .{
        .turns = @as(f64, @floatFromInt(turns)) / seconds,
        .lines = @as(f64, @floatFromInt(lines)) / seconds,
        .steps = @as(f64, @floatFromInt(steps)) / seconds,
        .usage = story.usage(),
    };
}

/// Loads a program (from ink's JSON or the image) and initializes a story on it, timed with
/// freeing both.
const Load = struct {
    gpa: Allocator,
    io: std.Io,
    format: enum { json, image },
    bytes: []const u8,
    limits: Limits,

    fn once(load: *const Load, iteration: u32) !u64 {
        _ = iteration;
        const gpa = load.gpa;
        const timer: common.Timer = .begin(load.io);
        var program = switch (load.format) {
            .json => try ink_json.load(gpa, load.bytes),
            .image => try program_image.load(gpa, load.bytes),
        };
        defer program.deinit(gpa);
        var story: Story = undefined;
        try story.init(gpa, &program, load.limits);
        story.deinit(gpa);
        return timer.nanoseconds(load.io);
    }
};

/// The runtime on ink's JSON: load (program and story) from the JSON and from the image,
/// play, and memory (the program plus the state's fixed budget). `fit` plays with limits
/// fitted to the bench's own play (margin 2) instead of the defaults.
fn measure_story(
    gpa: Allocator,
    io: std.Io,
    name: []const u8,
    json: []const u8,
    fit: bool,
) !Measurement {
    var counting = CountingAllocator.init(gpa);
    var program = try ink_json.load(counting.allocator(), json);
    defer program.deinit(counting.allocator());
    const program_bytes = counting.bytes_live;
    const limits: Limits = if (fit)
        limits_module.fitted((try measure_play(gpa, io, &program, .{})).usage, 2)
    else
        .{};
    var image: std.Io.Writer.Allocating = .init(gpa);
    defer image.deinit();
    try program_image.write(&program, &image.writer);
    var load: Load = .{ .gpa = gpa, .io = io, .format = .json, .bytes = json, .limits = limits };
    const load_nanoseconds = try mean_nanoseconds(&load, Load.once, loads_count);
    load.format = .image;
    load.bytes = image.written();
    const image_load_nanoseconds = try mean_nanoseconds(&load, Load.once, loads_count);
    const rate = try measure_play(gpa, io, &program, limits);
    return .{
        .name = name,
        .load_microseconds = load_nanoseconds / 1e3,
        .image_load_microseconds = image_load_nanoseconds / 1e3,
        .image_bytes = image.written().len,
        .play_turns_per_second = rate.turns,
        .play_lines_per_second = rate.lines,
        .play_steps_per_second = rate.steps,
        .loaded_bytes = program_bytes + limits.bytes_total(State.shape_of(&program)),
        .instructions_count = program.instructions_count(),
    };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const cwd = std.Io.Dir.cwd();
    const limit: std.Io.Limit = .limited(1 << 24);
    const crime_source = try cwd.readFileAlloc(io, "test/fixture/crime_scene.ink", arena, limit);
    const crime_json_path = "test/ground_truth/crime_scene.ink.json";
    const crime_json = try cwd.readFileAlloc(io, crime_json_path, arena, limit);
    const generated_json_path = "test/fixture/bench/generated.ink.json";
    const generated_json = try cwd.readFileAlloc(io, generated_json_path, arena, limit);
    const generated = try generate_story(arena);
    const story_measurements = [_]Measurement{
        try measure_story(gpa, io, "crime_scene", crime_json, false),
        try measure_story(gpa, io, "crime_scene, fitted limits", crime_json, true),
        try measure_story(gpa, io, "generated (1000 knots)", generated_json, false),
        try measure_story(gpa, io, "generated, fitted limits", generated_json, true),
    };
    const compiler_measurements = [_]CompilerMeasurement{
        try measure_compiler(gpa, io, "crime_scene", crime_source),
        try measure_compiler(gpa, io, "generated (1000 knots)", generated),
    };
    try write_runtime_report(arena, io, &story_measurements);
    try write_compiler_report(arena, io, &compiler_measurements);
}

fn write_runtime_report(arena: Allocator, io: std.Io, measurements: []const Measurement) !void {
    var section: std.Io.Writer.Allocating = .init(arena);
    const writer = &section.writer;
    const markers = try Markers.of(arena, "bench-runtime");
    try writer.print("{s}\n### Runtime, {t}\n\n", .{ markers.start, builtin.mode });
    try writer.writeAll("| Story | Load (µs) | Image load (µs) | Turns/s | Lines/s | " ++
        "Instructions/s | Bytes (program + state) | Image bytes | Instructions | " ++
        "Bytes/instruction |\n|---|---|---|---|---|---|---|---|---|---|\n");
    for (measurements) |m| {
        const per_instruction = @as(f64, @floatFromInt(m.loaded_bytes)) /
            @as(f64, @floatFromInt(m.instructions_count));
        const row = "| {s} | {d:.1} | {d:.1} | {d:.0} | {d:.0} | {d:.0} | {d} | {d} | {d} " ++
            "| {d:.1} |\n";
        try writer.print(row, .{
            m.name,                  m.load_microseconds,     m.image_load_microseconds,
            m.play_turns_per_second, m.play_lines_per_second, m.play_steps_per_second,
            m.loaded_bytes,          m.image_bytes,           m.instructions_count,
            per_instruction,
        });
    }
    try writer.print(
        "\nThe state is the limits' fixed budget, allocated once: the defaults, or limits " ++
            "fitted to the bench's own play with margin 2.\n{s}\n",
        .{markers.end},
    );
    try write_section(arena, io, section.written(), markers);
}

fn write_compiler_report(
    arena: Allocator,
    io: std.Io,
    measurements: []const CompilerMeasurement,
) !void {
    var section: std.Io.Writer.Allocating = .init(arena);
    const writer = &section.writer;
    const markers = try Markers.of(arena, "bench-compile");
    try writer.print("{s}\n### Compiler, {t}\n\n", .{ markers.start, builtin.mode });
    try writer.writeAll("| Story | Compile (ms) | Peak bytes |\n|---|---|---|\n");
    for (measurements) |m| {
        try writer.print("| {s} | {d:.2} | {d} |\n", .{ m.name, m.milliseconds, m.peak_bytes });
    }
    try writer.print(
        "\nSource to JSON; the time is the mean of {d} compiles.\n{s}\n",
        .{ compiles_count, markers.end },
    );
    try write_section(arena, io, section.written(), markers);
}

/// The markers around a generated section of the report, for this build mode.
const Markers = struct {
    start: []const u8,
    end: []const u8,

    fn of(arena: Allocator, name: []const u8) !Markers {
        const mode = builtin.mode;
        return .{
            .start = try std.fmt.allocPrint(arena, "<!-- {s}:{t}:start -->", .{ name, mode }),
            .end = try std.fmt.allocPrint(arena, "<!-- {s}:{t}:end -->", .{ name, mode }),
        };
    }
};

/// Replaces the marked section of the report, or appends it.
fn write_section(arena: Allocator, io: std.Io, section: []const u8, markers: Markers) !void {
    const cwd = std.Io.Dir.cwd();
    const existing = cwd.readFileAlloc(io, report_path, arena, .limited(1 << 22)) catch "";
    const start = std.mem.indexOf(u8, existing, markers.start);
    const end = std.mem.indexOf(u8, existing, markers.end);
    const text = if (start != null and end != null)
        try std.mem.concat(arena, u8, &.{
            existing[0..start.?],
            section,
            existing[end.? + markers.end.len + 1 ..],
        })
    else
        try std.mem.concat(arena, u8, &.{ existing, "\n", section });
    try cwd.writeFile(io, .{ .sub_path = report_path, .data = text });
}
