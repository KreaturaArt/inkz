//! `zig build bench` (plan P0.6, P6b, P9.4): the runtime and the compiler, in the build mode
//! it was built with. Measures load time, play throughput, memory per instruction, compile
//! time and peak memory on crime_scene and on a generated large story, and writes sections of
//! docs/benchmarks.md between markers for this mode.
//!
//! The runtime plays ink's JSON of the stories (test/ground_truth/crime_scene.ink.json,
//! test/fixture/bench/generated.ink.json) with seeded choices, as the P0.6 baseline played the
//! old runtime, so turns/s and lines/s compare with it; the baseline sections are kept as they
//! were measured.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const new_compiler = @import("compiler/compile.zig");
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

const PlayRate = struct { turns: f64, lines: f64, steps: f64, usage: limits_module.Usage };

/// The new compiler's source to JSON (as the old compiler's `compile`).
fn compile_new(gpa: std.mem.Allocator, source: []const u8) ![]u8 {
    assert(source.len > 0);
    var program = try new_compiler.compile_source(gpa, source);
    defer program.deinit(gpa);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try ink_json.serialize(gpa, &program, &out.writer);
    const json = try out.toOwnedSlice();
    assert(json.len > 0);
    return json;
}

const CompilerMeasurement = struct {
    name: []const u8,
    old_milliseconds: f64,
    new_milliseconds: f64,
    old_peak_bytes: u64,
    new_peak_bytes: u64,
};

/// The old compiler's last measurements (source to JSON, by story, ReleaseSafe then
/// ReleaseFast), taken before P9.2 deleted it.
const OldCompiler = struct { milliseconds: f64, peak_bytes: u64 };
const old_compiler_safe = [_]OldCompiler{
    .{ .milliseconds = 0.27, .peak_bytes = 535_918 },
    .{ .milliseconds = 4.53, .peak_bytes = 13_067_678 },
};
const old_compiler_fast = [_]OldCompiler{
    .{ .milliseconds = 0.17, .peak_bytes = 513_047 },
    .{ .milliseconds = 3.15, .peak_bytes = 12_680_076 },
};

/// The new compiler from source to JSON (mean time over `compiles_count` runs, and peak
/// bytes), next to the old compiler's recorded numbers for story `story`.
fn measure_compiler(
    gpa: std.mem.Allocator,
    io: std.Io,
    name: []const u8,
    story: u32,
    source: []const u8,
) !CompilerMeasurement {
    assert(name.len > 0);
    assert(source.len > 0);
    const old = if (builtin.mode == .fast) old_compiler_fast else old_compiler_safe;
    var result: CompilerMeasurement = .{
        .name = name,
        .old_milliseconds = old[story].milliseconds,
        .new_milliseconds = 0,
        .old_peak_bytes = old[story].peak_bytes,
        .new_peak_bytes = 0,
    };
    const start = std.Io.Timestamp.now(io, .awake);
    for (0..compiles_count) |_| gpa.free(try compile_new(gpa, source));
    const nanoseconds: f64 = @floatFromInt(elapsed_nanoseconds(io, start));
    result.new_milliseconds = nanoseconds / compiles_count / 1e6;
    var new_counting = CountingAllocator.init(gpa);
    new_counting.allocator().free(try compile_new(new_counting.allocator(), source));
    result.new_peak_bytes = new_counting.bytes_peak;
    assert(new_counting.bytes_live == 0);
    return result;
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

const ink_json = @import("core/ink_json.zig");
const limits_module = @import("core/limits.zig");
const Limits = limits_module.Limits;
const Program = @import("core/program.zig").Program;
const NewStory = @import("runtime/story.zig").Story;
const Severity = @import("runtime/state.zig").Diagnostic.Severity;

fn ignore_message(context: ?*anyopaque, message: []const u8, severity: Severity) void {
    assert(context == null);
    assert(message.len > 0 or severity == .warning);
}

/// Plays the new runtime `plays_count` times with the baseline's seeded choices.
fn measure_play_new(
    gpa: std.mem.Allocator,
    io: std.Io,
    program: *const Program,
    limits: Limits,
) !PlayRate {
    assert(program.containers.len > 0);
    var story: NewStory = undefined;
    try story.init(gpa, program, limits);
    defer story.deinit(gpa);
    story.on_error = ignore_message;
    var turns: u64 = 0;
    var lines: u64 = 0;
    const steps_before = story.steps_total;
    const start = std.Io.Timestamp.now(io, .awake);
    for (0..plays_count) |play| {
        try story.reset_state();
        var random = DotnetRandom.init(@intCast(play + 1));
        var turn: u32 = 0;
        while (turn < turns_max) : (turn += 1) {
            while (story.can_continue()) {
                _ = try story.cont();
                lines += 1;
            }
            const choices_count = story.visible_choices_count();
            if (choices_count == 0) break;
            const index: u32 = @intCast(@mod(random.next(), @as(i32, @intCast(choices_count))));
            try story.choose_choice_index(index);
        }
        turns += turn;
    }
    const seconds = @as(f64, @floatFromInt(elapsed_nanoseconds(io, start))) / 1e9;
    assert(seconds > 0);
    const steps = story.steps_total - steps_before;
    return .{
        .turns = @as(f64, @floatFromInt(turns)) / seconds,
        .lines = @as(f64, @floatFromInt(lines)) / seconds,
        .steps = @as(f64, @floatFromInt(steps)) / seconds,
        .usage = story.usage(),
    };
}

/// The new runtime on ink's JSON: load (program and story), play, and memory (the program
/// plus the state's fixed budget).
fn measure_story_new(
    gpa: std.mem.Allocator,
    io: std.Io,
    name: []const u8,
    json: []const u8,
    fit: bool,
) !Measurement {
    assert(json.len > 0);
    var limits: Limits = .{};
    if (fit) {
        // The limits a full bench play needs, with margin 2 (P10.2).
        var measured = try ink_json.load(gpa, json);
        defer measured.deinit(gpa);
        limits = limits_module.fitted((try measure_play_new(gpa, io, &measured, .{})).usage, 2);
    }
    const start = std.Io.Timestamp.now(io, .awake);
    for (0..loads_count) |_| {
        var program = try ink_json.load(gpa, json);
        var story: NewStory = undefined;
        try story.init(gpa, &program, limits);
        story.deinit(gpa);
        program.deinit(gpa);
    }
    const load_nanoseconds: f64 = @floatFromInt(elapsed_nanoseconds(io, start));
    const load_microseconds = load_nanoseconds / loads_count / 1000.0;
    var counting = CountingAllocator.init(gpa);
    var program = try ink_json.load(counting.allocator(), json);
    defer program.deinit(counting.allocator());
    const program_bytes = counting.bytes_live;
    const state_bytes = limits.bytes_total(@import("runtime/state.zig").State.shape_of(&program));
    const rate = try measure_play_new(gpa, io, &program, limits);
    const measurement: Measurement = .{
        .name = name,
        .load_microseconds = load_microseconds,
        .play_turns_per_second = rate.turns,
        .play_lines_per_second = rate.lines,
        .play_steps_per_second = rate.steps,
        .loaded_bytes = program_bytes + state_bytes,
        .runtime_objects_count = program.instructions_count(),
        .compile_milliseconds = 0,
    };
    assert(measurement.loaded_bytes > program_bytes);
    return measurement;
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
    const crime_json = try cwd.readFileAlloc(
        io,
        "test/ground_truth/crime_scene.ink.json",
        gpa,
        .limited(1 << 24),
    );
    defer gpa.free(crime_json);
    const generated_json = try cwd.readFileAlloc(
        io,
        "test/fixture/bench/generated.ink.json",
        gpa,
        .limited(1 << 24),
    );
    defer gpa.free(generated_json);
    const new_measurements = [_]Measurement{
        try measure_story_new(gpa, io, "crime_scene", crime_json, false),
        try measure_story_new(gpa, io, "crime_scene, fitted limits", crime_json, true),
        try measure_story_new(gpa, io, "generated (1000 knots)", generated_json, false),
        try measure_story_new(gpa, io, "generated, fitted limits", generated_json, true),
    };
    const compiler_measurements = [_]CompilerMeasurement{
        try measure_compiler(gpa, io, "crime_scene", 0, crime_source),
        try measure_compiler(gpa, io, "generated (1000 knots)", 1, generated),
    };
    try write_new_report(init.arena.allocator(), io, &new_measurements);
    try write_compiler_report(init.arena.allocator(), io, &compiler_measurements);
    assert(new_measurements.len == 2 * compiler_measurements.len);
}

fn mode_name() []const u8 {
    comptime assert(@typeInfo(std.builtin.OptimizeMode).@"enum".field_names.len == 4);
    comptime assert(@sizeOf(std.builtin.OptimizeMode) == 1);
    return switch (builtin.mode) {
        .Debug => "Debug",
        .ReleaseSafe => "ReleaseSafe",
        .ReleaseFast => "ReleaseFast",
        .ReleaseSmall => "ReleaseSmall",
    };
}

fn write_new_report(arena: std.mem.Allocator, io: std.Io, measurements: []const Measurement) !void {
    assert(measurements.len > 0);
    assert(measurements.len <= 8);
    const mode = mode_name();
    var section: std.Io.Writer.Allocating = .init(arena);
    const writer = &section.writer;
    const start_marker = try std.fmt.allocPrint(arena, "<!-- bench-new:{s}:start -->", .{mode});
    const end_marker = try std.fmt.allocPrint(arena, "<!-- bench-new:{s}:end -->", .{mode});
    try writer.print("{s}\n### New runtime, {s}\n\n", .{ start_marker, mode });
    try writer.writeAll("| Story | Load (µs) | Turns/s | Lines/s | Instructions/s | Bytes " ++
        "(program + state) | Instructions | Bytes/instruction |\n" ++
        "|---|---|---|---|---|---|---|---|\n");
    for (measurements) |m| {
        const per_object = @as(f64, @floatFromInt(m.loaded_bytes)) /
            @as(f64, @floatFromInt(m.runtime_objects_count));
        try writer.print("| {s} | {d:.1} | {d:.0} | {d:.0} | {d:.0} | {d} | {d} | {d:.1} |\n", .{
            m.name,                  m.load_microseconds,     m.play_turns_per_second,
            m.play_lines_per_second, m.play_steps_per_second, m.loaded_bytes,
            m.runtime_objects_count, per_object,
        });
    }
    try writer.print(
        "\nThe state is the limits' fixed budget, allocated once: the defaults, or limits " ++
            "fitted to the bench's own play with margin 2 (P10.2).\n{s}\n",
        .{end_marker},
    );
    try write_section(arena, io, section.written(), start_marker, end_marker);
}

fn write_compiler_report(
    arena: std.mem.Allocator,
    io: std.Io,
    measurements: []const CompilerMeasurement,
) !void {
    assert(measurements.len > 0);
    assert(measurements.len <= 8);
    const mode = mode_name();
    var section: std.Io.Writer.Allocating = .init(arena);
    const writer = &section.writer;
    const start_marker = try std.fmt.allocPrint(arena, "<!-- bench-compile:{s}:start -->", .{mode});
    const end_marker = try std.fmt.allocPrint(arena, "<!-- bench-compile:{s}:end -->", .{mode});
    try writer.print("{s}\n### Compilers, {s}\n\n", .{ start_marker, mode });
    try writer.writeAll("| Story | Old compile (ms) | New compile (ms) | Old peak bytes | " ++
        "New peak bytes | Old/new peak |\n|---|---|---|---|---|---|\n");
    for (measurements) |m| {
        const ratio = @as(f64, @floatFromInt(m.old_peak_bytes)) /
            @as(f64, @floatFromInt(m.new_peak_bytes));
        try writer.print("| {s} | {d:.2} | {d:.2} | {d} | {d} | {d:.2} |\n", .{
            m.name,           m.old_milliseconds, m.new_milliseconds,
            m.old_peak_bytes, m.new_peak_bytes,   ratio,
        });
    }
    try writer.print("\nSource to JSON, both; the time is the mean of {d} compiles. The old " ++
        "compiler's numbers are its last measurement, before P9.2 deleted it.\n{s}\n", .{
        compiles_count,
        end_marker,
    });
    try write_section(arena, io, section.written(), start_marker, end_marker);
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
