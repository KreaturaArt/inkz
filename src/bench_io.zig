//! `zig build bench-io`: loading and storing a Program, as ink's JSON (`ink_json.load`,
//! `ink_json.serialize`) and as the binary program image (`program_image.load`,
//! `program_image.write`), on crime_scene and on the generated 1000-knot story, in the build
//! mode it was built with.
//!
//! Each measurement times one operation per sample, after warm-up, until `samples_max`
//! samples or `budget_nanoseconds` have passed. The results are printed and appended to
//! `bench/load_store.jsonl`, one JSON object per line and measurement, with the commit, the
//! mode and the machine, so the file keeps the history of every run that was committed.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const ink_json = @import("core/ink_json.zig");
const program_image = @import("core/program_image.zig");
const Program = @import("core/program.zig").Program;

const Allocator = std.mem.Allocator;
const results_path = "bench/load_store.jsonl";
const warmup_count = 3;
pub const samples_min = 10;
const samples_max = 500;
const budget_nanoseconds = 1_000_000_000;

const Story = struct { name: []const u8, json_path: []const u8 };
const stories = [_]Story{
    .{ .name = "crime_scene", .json_path = "test/ground_truth/crime_scene.ink.json" },
    .{ .name = "generated_1000_knots", .json_path = "test/fixture/bench/generated.ink.json" },
};

pub const Format = enum { json, image };
pub const Operation = enum { load, store };

/// What a run shares: when, which code, which build, which machine.
pub const Run = struct {
    timestamp: []const u8,
    commit: []const u8,
    dirty: bool,
    zig: []const u8,
    mode: []const u8,
    target: []const u8,
    cpu: []const u8,
};

/// One line of the results file.
pub const Record = struct {
    timestamp: []const u8,
    commit: []const u8,
    dirty: bool,
    zig: []const u8,
    mode: []const u8,
    target: []const u8,
    cpu: []const u8,
    story: []const u8,
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

pub const Stats = struct { samples: u32, min: u64, median: u64, mean: u64, max: u64 };

pub fn stats_of(samples: []u64) Stats {
    assert(samples.len >= samples_min);
    assert(samples.len <= samples_max);
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    var total: u128 = 0;
    for (samples) |sample| total += sample;
    const stats: Stats = .{
        .samples = @intCast(samples.len),
        .min = samples[0],
        .median = samples[samples.len / 2],
        .mean = @intCast(total / samples.len),
        .max = samples[samples.len - 1],
    };
    assert(stats.min <= stats.median and stats.median <= stats.max);
    assert(stats.min <= stats.mean and stats.mean <= stats.max);
    return stats;
}

/// The inputs of one story's measurements: its JSON, its program, the program's own JSON
/// and its image.
pub const Subject = struct {
    json: []const u8,
    program: Program,
    image: []u8,
    json_written: []u8,

    pub fn init(gpa: Allocator, json: []const u8) !Subject {
        assert(json.len > 0);
        var program = try ink_json.load(gpa, json);
        errdefer program.deinit(gpa);
        var image: std.Io.Writer.Allocating = .init(gpa);
        errdefer image.deinit();
        try program_image.write(&program, &image.writer);
        var written: std.Io.Writer.Allocating = .init(gpa);
        errdefer written.deinit();
        try ink_json.serialize(gpa, &program, &written.writer);
        const subject: Subject = .{
            .json = json,
            .program = program,
            .image = try image.toOwnedSlice(),
            .json_written = try written.toOwnedSlice(),
        };
        assert(subject.image.len == program_image.image_bytes(&subject.program));
        return subject;
    }

    pub fn deinit(subject: *Subject, gpa: Allocator) void {
        assert(subject.image.len > 0);
        assert(subject.json_written.len > 0);
        subject.program.deinit(gpa);
        gpa.free(subject.image);
        gpa.free(subject.json_written);
        subject.* = undefined;
    }

    /// Both formats round-trip: what a load reads, a store writes back the same.
    pub fn check_round_trips(subject: *const Subject, gpa: Allocator) !void {
        assert(subject.program.check() == .ok);
        var from_image = try program_image.load(gpa, subject.image);
        defer from_image.deinit(gpa);
        var image: std.Io.Writer.Allocating = .init(gpa);
        defer image.deinit();
        try program_image.write(&from_image, &image.writer);
        if (!std.mem.eql(u8, image.written(), subject.image)) return error.ImageRoundTrip;
        var from_json = try ink_json.load(gpa, subject.json_written);
        defer from_json.deinit(gpa);
        var json: std.Io.Writer.Allocating = .init(gpa);
        defer json.deinit();
        try ink_json.serialize(gpa, &from_json, &json.writer);
        if (!std.mem.eql(u8, json.written(), subject.json_written)) return error.JsonRoundTrip;
    }
};

/// One timed operation; returns its nanoseconds.
fn time_once(
    gpa: Allocator,
    io: std.Io,
    subject: *const Subject,
    format: Format,
    operation: Operation,
    out: *std.Io.Writer.Allocating,
) !u64 {
    assert(subject.image.len > 0);
    out.clearRetainingCapacity();
    const start = std.Io.Timestamp.now(io, .awake);
    switch (operation) {
        .load => {
            var program = switch (format) {
                .json => try ink_json.load(gpa, subject.json),
                .image => try program_image.load(gpa, subject.image),
            };
            const elapsed = elapsed_since(io, start);
            program.deinit(gpa);
            return elapsed;
        },
        .store => switch (format) {
            .json => try ink_json.serialize(gpa, &subject.program, &out.writer),
            .image => try program_image.write(&subject.program, &out.writer),
        },
    }
    const elapsed = elapsed_since(io, start);
    assert(out.written().len > 0);
    return elapsed;
}

fn elapsed_since(io: std.Io, start: std.Io.Timestamp) u64 {
    const nanoseconds = start.durationTo(std.Io.Timestamp.now(io, .awake)).toNanoseconds();
    assert(nanoseconds >= 0);
    assert(nanoseconds < std.math.maxInt(u64));
    return @intCast(nanoseconds);
}

fn measure(
    gpa: Allocator,
    io: std.Io,
    subject: *const Subject,
    format: Format,
    operation: Operation,
) !Stats {
    assert(subject.json.len > 0);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.ensureTotalCapacity(@max(subject.json_written.len, subject.image.len));
    for (0..warmup_count) |_| _ = try time_once(gpa, io, subject, format, operation, &out);
    var samples: [samples_max]u64 = undefined;
    var count: u32 = 0;
    var total: u64 = 0;
    while (count < samples_max and (count < samples_min or total < budget_nanoseconds)) {
        samples[count] = try time_once(gpa, io, subject, format, operation, &out);
        total += samples[count];
        count += 1;
    }
    assert(count >= samples_min);
    assert(count <= samples_max);
    return stats_of(samples[0..count]);
}

/// The record for `stats`: a load reads the input JSON (inklecate's) or the image; a store
/// writes this runtime's JSON or the image.
pub fn record_of(
    run: Run,
    story: []const u8,
    subject: *const Subject,
    format: Format,
    operation: Operation,
    stats: Stats,
) Record {
    assert(stats.median > 0);
    const bytes: u64 = switch (format) {
        .json => if (operation == .load) subject.json.len else subject.json_written.len,
        .image => subject.image.len,
    };
    const seconds = @as(f64, @floatFromInt(stats.median)) / 1e9;
    const record: Record = .{
        .timestamp = run.timestamp,
        .commit = run.commit,
        .dirty = run.dirty,
        .zig = run.zig,
        .mode = run.mode,
        .target = run.target,
        .cpu = run.cpu,
        .story = story,
        .format = format,
        .operation = operation,
        .bytes = bytes,
        .samples = stats.samples,
        .min_ns = stats.min,
        .median_ns = stats.median,
        .mean_ns = stats.mean,
        .max_ns = stats.max,
        .megabytes_per_second = @as(f64, @floatFromInt(bytes)) / 1e6 / seconds,
    };
    assert(record.min_ns <= record.median_ns and record.median_ns <= record.max_ns);
    return record;
}

/// Runs `git` in the working directory; null if it can't.
fn git(arena: Allocator, io: std.Io, argv: []const []const u8) ?[]const u8 {
    assert(argv.len > 1);
    assert(std.mem.eql(u8, argv[0], "git"));
    const result = std.process.run(arena, io, .{ .argv = argv }) catch return null;
    if (result.term != .exited or result.term.exited != 0) return null;
    return std.mem.trim(u8, result.stdout, " \n");
}

pub fn run_info(arena: Allocator, io: std.Io) !Run {
    assert(builtin.mode != .debug);
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
    const run: Run = .{
        .timestamp = timestamp,
        .commit = commit orelse "unknown",
        .dirty = status.len > 0,
        .zig = builtin.zig_version_string,
        .mode = @tagName(builtin.mode),
        .target = try std.fmt.allocPrint(arena, "{t}-{t}", .{ builtin.cpu.arch, builtin.os.tag }),
        .cpu = builtin.cpu.model.name,
    };
    assert(run.timestamp.len == 20);
    return run;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const run = try run_info(arena, io);
    var lines: std.Io.Writer.Allocating = .init(arena);
    const dirty = if (run.dirty) " (dirty)" else "";
    std.debug.print("{s} {s}{s}, {s}\n", .{ run.mode, run.commit, dirty, run.cpu });
    std.debug.print("{s:<22} {s:<6} {s:<6} {s:>10} {s:>12} {s:>10}\n", .{
        "story", "format", "op", "bytes", "median µs", "MB/s",
    });
    for (stories) |story| {
        const limit: std.Io.Limit = .limited(1 << 26);
        const json = try std.Io.Dir.cwd().readFileAlloc(io, story.json_path, arena, limit);
        var subject: Subject = try .init(gpa, json);
        defer subject.deinit(gpa);
        try subject.check_round_trips(gpa);
        for ([_]Format{ .json, .image }) |format| {
            for ([_]Operation{ .load, .store }) |operation| {
                const stats = try measure(gpa, io, &subject, format, operation);
                const record = record_of(run, story.name, &subject, format, operation, stats);
                try std.json.Stringify.value(record, .{}, &lines.writer);
                try lines.writer.writeByte('\n');
                print_record(&record);
            }
        }
    }
    try append_results(arena, io, results_path, lines.written());
}

fn print_record(record: *const Record) void {
    assert(record.median_ns > 0);
    assert(record.bytes > 0);
    const microseconds = @as(f64, @floatFromInt(record.median_ns)) / 1e3;
    std.debug.print("{s:<22} {t:<6} {t:<6} {d:>10} {d:>12.1} {d:>10.1}\n", .{
        record.story,
        record.format,
        record.operation,
        record.bytes,
        microseconds,
        record.megabytes_per_second,
    });
}

/// Appends `lines` to the results file at `path`, creating it (and its directory) if needed.
pub fn append_results(arena: Allocator, io: std.Io, path: []const u8, lines: []const u8) !void {
    assert(lines.len > 0);
    assert(lines[lines.len - 1] == '\n');
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, std.fs.path.dirname(path).?);
    const limit: std.Io.Limit = .limited(1 << 26);
    const existing = cwd.readFileAlloc(io, path, arena, limit) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    const text = try std.mem.concat(arena, u8, &.{ existing, lines });
    try cwd.writeFile(io, .{ .sub_path = path, .data = text });
    const count = std.mem.count(u8, lines, "\n");
    std.debug.print("appended {d} records to {s}\n", .{ count, path });
}
