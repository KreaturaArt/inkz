//! `zig build bench` (plan P0.6): the old runtime's baseline, in the build mode it was built
//! with. Measures load time, play throughput, memory per runtime object, compile time and
//! peak RSS on crime_scene and on a generated large story, and writes a section of
//! docs/benchmarks.md between markers for this mode.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Story = @import("runtime/story.zig").Story;
const old_compiler = @import("compiler/compiler.zig");
const CountingAllocator = @import("core/counting_allocator.zig").CountingAllocator;
const DotnetRandom = @import("core/dotnet_random.zig").DotnetRandom;

const report_path = "docs/benchmarks.md";
const loads_count = 200;
const plays_count = 200;
const compiles_count = 20;
const generated_knots_count = 1000;
const turns_max = 200;

const Measurement = struct {
    name: []const u8,
    load_microseconds: f64,
    play_turns_per_second: f64,
    play_lines_per_second: f64,
    play_steps_per_second: f64,
    loaded_bytes: u64,
    runtime_objects_count: u64,
    compile_milliseconds: f64,
};

fn elapsed_nanoseconds(io: std.Io, start: std.Io.Timestamp) u64 {
    const end = std.Io.Timestamp.now(io, .awake);
    const nanoseconds = start.durationTo(end).toNanoseconds();
    assert(nanoseconds >= 0);
    assert(nanoseconds < std.math.maxInt(u64));
    return @intCast(nanoseconds);
}

fn measure_load(gpa: std.mem.Allocator, io: std.Io, json: []const u8) !f64 {
    assert(json.len > 0);
    const start = std.Io.Timestamp.now(io, .awake);
    for (0..loads_count) |_| {
        var story = try Story.initFromJson(gpa, json);
        story.deinit();
    }
    const nanoseconds = elapsed_nanoseconds(io, start);
    assert(nanoseconds > 0);
    return @as(f64, @floatFromInt(nanoseconds)) / loads_count / 1000.0;
}

const PlayRate = struct { turns: f64, lines: f64, steps: f64 };

/// Plays the story `plays_count` times with seeded random choices (seeds 1, 2, ...).
fn measure_play(gpa: std.mem.Allocator, io: std.Io, json: []const u8) !PlayRate {
    assert(json.len > 0);
    var turns: u64 = 0;
    var lines: u64 = 0;
    var steps: u64 = 0;
    const start = std.Io.Timestamp.now(io, .awake);
    for (0..plays_count) |play| {
        var story = try Story.initFromJson(gpa, json);
        defer story.deinit();
        var random = DotnetRandom.init(@intCast(play + 1));
        var turn: u32 = 0;
        while (turn < turns_max) : (turn += 1) {
            while (story.canContinue()) {
                const out = try story.cont();
                lines += std.mem.count(u8, out, "\n");
                gpa.free(out);
            }
            const choices_count = story.currentChoices().len;
            if (choices_count == 0) break;
            const index: usize = @intCast(@mod(random.next(), @as(i32, @intCast(choices_count))));
            try story.chooseChoiceIndex(index);
        }
        turns += turn;
        steps += story.steps_count;
    }
    const seconds = @as(f64, @floatFromInt(elapsed_nanoseconds(io, start))) / 1e9;
    assert(seconds > 0);
    return .{
        .turns = @as(f64, @floatFromInt(turns)) / seconds,
        .lines = @as(f64, @floatFromInt(lines)) / seconds,
        .steps = @as(f64, @floatFromInt(steps)) / seconds,
    };
}

const Footprint = struct { bytes: u64, objects: u64 };

/// Bytes the loaded story keeps, and how many runtime objects (instructions) it holds.
fn measure_footprint(gpa: std.mem.Allocator, json: []const u8) !Footprint {
    var counting = CountingAllocator.init(gpa);
    var story = try Story.initFromJson(counting.allocator(), json);
    defer story.deinit();
    var objects: u64 = 0;
    for (story.containers) |container| objects += container.content.len;
    assert(objects > 0);
    assert(counting.bytes_live > 0);
    return .{ .bytes = counting.bytes_live, .objects = objects };
}

fn measure_compile(gpa: std.mem.Allocator, io: std.Io, source: []const u8) !f64 {
    assert(source.len > 0);
    const start = std.Io.Timestamp.now(io, .awake);
    for (0..compiles_count) |_| {
        const json = try old_compiler.compile(gpa, source);
        gpa.free(json);
    }
    const nanoseconds = elapsed_nanoseconds(io, start);
    assert(nanoseconds > 0);
    return @as(f64, @floatFromInt(nanoseconds)) / compiles_count / 1e6;
}

fn measure_story(
    gpa: std.mem.Allocator,
    io: std.Io,
    name: []const u8,
    source: []const u8,
) !Measurement {
    assert(name.len > 0);
    const json = try old_compiler.compile(gpa, source);
    defer gpa.free(json);
    const rate = try measure_play(gpa, io, json);
    const footprint = try measure_footprint(gpa, json);
    const measurement: Measurement = .{
        .name = name,
        .load_microseconds = try measure_load(gpa, io, json),
        .play_turns_per_second = rate.turns,
        .play_lines_per_second = rate.lines,
        .play_steps_per_second = rate.steps,
        .loaded_bytes = footprint.bytes,
        .runtime_objects_count = footprint.objects,
        .compile_milliseconds = try measure_compile(gpa, io, source),
    };
    assert(measurement.load_microseconds > 0);
    return measurement;
}

/// A large story: `generated_knots_count` knots, each with text, a variable update and two
/// choices that divert onwards, so play visits many containers.
fn generate_story(gpa: std.mem.Allocator) ![]u8 {
    comptime assert(generated_knots_count > 7);
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
    assert(source.written().len > generated_knots_count);
    return source.toOwnedSlice();
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    const crime_path = "test/fixture/crime_scene.ink";
    const crime_source = try cwd.readFileAlloc(io, crime_path, gpa, .limited(1 << 24));
    assert(crime_source.len > 0);
    defer gpa.free(crime_source);
    const generated = try generate_story(gpa);
    defer gpa.free(generated);
    const measurements = [_]Measurement{
        try measure_story(gpa, io, "crime_scene", crime_source),
        try measure_story(gpa, io, "generated (1000 knots)", generated),
    };
    const usage = std.posix.getrusage(std.c.rusage.SELF);
    // macOS reports bytes, Linux kilobytes.
    const rss_unit: u64 = if (builtin.os.tag == .linux) 1024 else 1;
    const rss_bytes: u64 = @as(u64, @intCast(usage.maxrss)) * rss_unit;
    try write_report(init.arena.allocator(), io, &measurements, rss_bytes);
    assert(measurements.len == 2);
}

fn write_report(
    arena: std.mem.Allocator,
    io: std.Io,
    measurements: []const Measurement,
    rss_bytes: u64,
) !void {
    assert(measurements.len > 0);
    const mode = switch (builtin.mode) {
        .Debug => "Debug",
        .ReleaseSafe => "ReleaseSafe",
        .ReleaseFast => "ReleaseFast",
        .ReleaseSmall => "ReleaseSmall",
    };
    var section: std.Io.Writer.Allocating = .init(arena);
    const writer = &section.writer;
    const start_marker = try std.fmt.allocPrint(arena, "<!-- bench:{s}:start -->", .{mode});
    const end_marker = try std.fmt.allocPrint(arena, "<!-- bench:{s}:end -->", .{mode});
    try writer.print("{s}\n### Old runtime, {s}\n\n", .{ start_marker, mode });
    try writer.writeAll("| Story | Load (µs) | Turns/s | Lines/s | Steps/s | Loaded bytes | " ++
        "Runtime objects | Bytes/object | Compile (ms) |\n|---|---|---|---|---|---|---|---|---|\n");
    for (measurements) |m| {
        const per_object = @as(f64, @floatFromInt(m.loaded_bytes)) /
            @as(f64, @floatFromInt(m.runtime_objects_count));
        assert(per_object > 0);
        const row = "| {s} | {d:.1} | {d:.0} | {d:.0} | {d:.0} | {d} | {d} | {d:.1} | {d:.2} |\n";
        try writer.print(row, .{
            m.name,                  m.load_microseconds,     m.play_turns_per_second,
            m.play_lines_per_second, m.play_steps_per_second, m.loaded_bytes,
            m.runtime_objects_count, per_object,              m.compile_milliseconds,
        });
    }
    try writer.print("\nPeak RSS of the whole run: {d} KiB. Plays use seeded random choices " ++
        "(.NET Random, seeds 1..{d}), at most {d} turns each.\n{s}\n", .{
        rss_bytes / 1024, plays_count, turns_max, end_marker,
    });
    try write_section(arena, io, section.written(), start_marker, end_marker);
    std.debug.print("bench ({s}) written to {s}\n", .{ mode, report_path });
}

/// Replaces the marked section of the report, or appends it.
fn write_section(
    arena: std.mem.Allocator,
    io: std.Io,
    section: []const u8,
    start_marker: []const u8,
    end_marker: []const u8,
) !void {
    assert(std.mem.startsWith(u8, section, start_marker));
    const cwd = std.Io.Dir.cwd();
    const existing = cwd.readFileAlloc(io, report_path, arena, .limited(1 << 22)) catch "";
    const start = std.mem.indexOf(u8, existing, start_marker);
    const end = std.mem.indexOf(u8, existing, end_marker);
    const text = if (start != null and end != null)
        try std.mem.concat(arena, u8, &.{
            existing[0..start.?],
            section,
            existing[end.? + end_marker.len + 1 ..],
        })
    else
        try std.mem.concat(arena, u8, &.{ existing, "\n", section });
    assert(text.len >= section.len);
    try cwd.writeFile(io, .{ .sub_path = report_path, .data = text });
}
