//! The differential swarm run (plan §3.4): generated stories, compiled and played by inkz and
//! by ink v1.2.1, compared.
//!
//! 1. `generate` writes `<n>.ink`, `<n>.actions` and `<n>.swarm` (the configuration line and
//!    the seed) into a directory.
//! 2. The C# harness (`mise run reference:swarm -- <dir>`, `ink_harness batch`) writes
//!    `<n>.ink.json` and `<n>.expected`, `<n>.compile_errors`, or `<n>.timeout` for a story
//!    ink can't finish.
//! 3. `check_directory` compiles and plays each story with inkz and compares:
//!    - compile acceptance: both compile, or both reject;
//!    - runtime: inklecate's JSON played by inkz against ink's transcript;
//!    - pipeline: inkz's own JSON played by inkz against ink's transcript;
//!    - structure: inkz's JSON against inklecate's.
//! 4. `reduce.features` (`reduce.zig`) drops one swarm feature at a time while a divergence
//!    stays (delta debugging over features: one oracle call per feature).

const std = @import("std");
const assert = std.debug.assert;
const fuzz_ink = @import("fuzz_ink.zig");
const oracle = @import("oracle.zig");
const compile = @import("../compiler/compile.zig");
const ink_json = @import("../core/ink_json.zig");
const Swarm = fuzz_ink.Swarm;

const file_bytes_max = 16 * 1024 * 1024;
/// The cap of each `continue_maximally` in a generated case: generated stories often loop.
pub const lines_max = 1000;

/// Case `index`'s generator seed in a run seeded with `seed`.
pub fn case_seed(seed: u64, index: u32) u64 {
    var bytes: [12]u8 = undefined;
    std.mem.writeInt(u64, bytes[0..8], seed, .little);
    std.mem.writeInt(u32, bytes[8..12], index, .little);
    return std.hash.Wyhash.hash(0x5eed, &bytes);
}

/// The host actions of a generated case: a seeded play, the globals, and the globals again
/// after a save is loaded into a fresh story.
pub fn write_actions(writer: *std.Io.Writer, seed: u64) !void {
    const play_seed: i32 = @bitCast(@as(u32, @truncate(seed)));
    try writer.print("lines_max {d}\nplay_seeded {d}\nglobals\nsave\nload_fresh\nglobals\n", .{
        lines_max,
        play_seed,
    });
}

/// Writes case `name` generated from `seed` with `swarm` (null: the one drawn from the
/// seed) into `directory`.
pub fn write_case(
    io: std.Io,
    directory: std.Io.Dir,
    name: []const u8,
    seed: u64,
    swarm: ?Swarm,
) !Swarm {
    assert(name.len > 0);
    var buffer: [fuzz_ink.source_bytes_max]u8 = undefined;
    // The draw comes first either way, so a candidate from `reduce.features` starts from the same
    // choices as the case it reduces.
    var prng: std.Random.DefaultPrng = .init(seed);
    const choices: fuzz_ink.Choices = .{ .random = prng.random() };
    const drawn = Swarm.draw(choices);
    const options: fuzz_ink.Options = .{ .swarm = swarm orelse drawn };
    const case = fuzz_ink.Generator.generate_case(choices, &buffer, options);
    var path: [64]u8 = undefined;
    try directory.writeFile(io, .{
        .sub_path = try std.fmt.bufPrint(&path, "{s}.ink", .{name}),
        .data = case.source,
    });
    var text: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&text);
    try write_actions(&writer, seed);
    try directory.writeFile(io, .{
        .sub_path = try std.fmt.bufPrint(&path, "{s}.actions", .{name}),
        .data = writer.buffered(),
    });
    writer = .fixed(&text);
    try writer.print("{f}\nseed {d}\n", .{ case.swarm, seed });
    try directory.writeFile(io, .{
        .sub_path = try std.fmt.bufPrint(&path, "{s}.swarm", .{name}),
        .data = writer.buffered(),
    });
    return case.swarm;
}

/// Writes `count` cases named `00000`... into `directory`, each with its drawn
/// configuration or, when given, `swarm`.
pub fn generate(io: std.Io, directory: std.Io.Dir, seed: u64, count: u32, swarm: ?Swarm) !void {
    assert(count > 0);
    for (0..count) |index| {
        var name: [16]u8 = undefined;
        const case_name = try std.fmt.bufPrint(&name, "{d:0>5}", .{index});
        _ = try write_case(io, directory, case_name, case_seed(seed, @intCast(index)), swarm);
    }
}

/// Why a case wasn't compared.
pub const Skip = enum {
    /// ink didn't finish the story in time.
    timeout,
    /// ink crashed the harness's process on it (a stack overflow).
    harness_crash,
    /// ink's harness hasn't run on it.
    pending,
    /// ink threw a .NET exception that isn't ink's (`DivideByZeroException` for an integer
    /// `/` or `%` by 0), where inkz reports a story error; the transcripts match up to it.
    ink_exception,
    /// inkz stopped at one of its limits (`ThreadLimit`, `FrameLimit`..., or a save that
    /// doesn't fit them to load, `SaveTooLarge`), which ink doesn't have; the transcripts
    /// match up to it.
    inkz_limit,
};

/// What a case's comparison found. `null` fields match.
pub const Verdict = struct {
    skipped: ?Skip = null,
    acceptance: ?[]const u8 = null,
    /// The first difference from ink's transcript, as `oracle.compare` gives it.
    runtime: ?[]const u8 = null,
    pipeline: ?[]const u8 = null,
    structure: bool = false,

    pub fn diverges(verdict: Verdict) bool {
        return verdict.acceptance != null or verdict.runtime != null or
            verdict.pipeline != null or verdict.structure;
    }
};

/// Replays `actions` on the story at `json_path` and returns the transcript (in this
/// process, or in a child that contains crashes).
pub const Replay = *const fn (
    arena: std.mem.Allocator,
    io: std.Io,
    json_path: []const u8,
    actions: []const u8,
) anyerror![]const u8;

fn read_optional(
    arena: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    name: []const u8,
    extension: []const u8,
) !?[]const u8 {
    const path = try std.fmt.allocPrint(arena, "{s}{s}", .{ name, extension });
    return directory.readFileAlloc(io, path, arena, .limited(file_bytes_max)) catch |err|
        switch (err) {
            error.FileNotFound => null,
            else => err,
        };
}

/// Without the provenance header the C# harness writes first.
fn without_header(text: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, text, "# generated by")) return text;
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse return "";
    return text[end + 1 ..];
}

/// Compares case `name` in `directory` (at `directory_path`, for the replay).
pub fn check_case(
    arena: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    directory_path: []const u8,
    name: []const u8,
    replay: Replay,
) !Verdict {
    if (try read_optional(arena, io, directory, name, ".timeout") != null) {
        return .{ .skipped = .timeout };
    }
    if (try read_optional(arena, io, directory, name, ".harness_crash") != null) {
        return .{ .skipped = .harness_crash };
    }
    const rejected = try read_optional(arena, io, directory, name, ".compile_errors") != null;
    const played = try read_optional(arena, io, directory, name, ".expected") != null;
    if (!rejected and !played) return .{ .skipped = .pending };
    const source = (try read_optional(arena, io, directory, name, ".ink")).?;
    const reference_json = try read_optional(arena, io, directory, name, ".ink.json");
    var program = compile.compile_source(arena, source) catch |err| {
        if (reference_json == null) return .{};
        const reason = try std.fmt.allocPrint(arena, "ink compiles it, inkz: {t}", .{err});
        return .{ .acceptance = reason };
    };
    defer program.deinit(arena);
    const reference = without_bom(reference_json orelse
        return .{ .acceptance = "inkz compiles it, ink rejects it" });
    var own: std.Io.Writer.Allocating = .init(arena);
    try ink_json.serialize(arena, &program, &own.writer);
    const own_json = own.written();
    var verdict: Verdict = .{
        .structure = !std.mem.eql(u8, own_json, reference) and
            !try oracle.json_equivalent(arena, own_json, reference),
    };
    const expected_file = try read_optional(arena, io, directory, name, ".expected") orelse
        return error.MissingExpected;
    const expected = without_header(expected_file);
    const actions = (try read_optional(arena, io, directory, name, ".actions")).?;
    // ink's JSON played by inkz isolates the runtime; inkz's own JSON adds the compiler.
    const reference_path = try case_path(arena, directory_path, name, ".ink.json");
    const runtime = try replay(arena, io, reference_path, actions);
    verdict.runtime = try oracle.compare(arena, expected, runtime);
    if (verdict.runtime != null) {
        verdict.skipped = try by_design(arena, expected, runtime);
        if (verdict.skipped != null) verdict.runtime = null;
        return verdict;
    }
    const own_name = try std.fmt.allocPrint(arena, "{s}.inkz.json", .{name});
    try directory.writeFile(io, .{ .sub_path = own_name, .data = own_json });
    const own_path = try case_path(arena, directory_path, name, ".inkz.json");
    const pipeline = try replay(arena, io, own_path, actions);
    verdict.pipeline = try oracle.compare(arena, expected, pipeline);
    if (verdict.pipeline != null) {
        verdict.skipped = try by_design(arena, expected, pipeline);
        if (verdict.skipped != null) verdict.pipeline = null;
    }
    return verdict;
}

/// Whether a difference is one inkz makes on purpose: ink threw an exception that isn't
/// ink's, or inkz stopped at a limit. Either way the transcripts must match up to that line.
fn by_design(arena: std.mem.Allocator, expected: []const u8, actual: []const u8) !?Skip {
    // Whichever comes first: ink's own exception or inkz's limit (a story whose text grows
    // without end hits inkz's heap limit before ink runs out of memory).
    const exception = marker_line(expected, "harness_exception: ");
    const limit = limit_line(actual);
    const exception_first = exception != null and (limit == null or exception.? <= limit.?);
    const skip: Skip, const line = if (exception_first)
        .{ .ink_exception, exception.? }
    else if (limit) |found|
        .{ .inkz_limit, found }
    else
        return null;
    const before_expected = first_lines(expected, line);
    const before_actual = first_lines(actual, line);
    return if (try oracle.compare(arena, before_expected, before_actual) == null) skip else null;
}

/// The index of the first line that starts with `prefix`.
fn marker_line(text: []const u8, prefix: []const u8) ?usize {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var index: usize = 0;
    while (lines.next()) |line| : (index += 1) {
        if (std.mem.startsWith(u8, line, prefix)) return index;
    }
    return null;
}

/// The index of the first `exception: "<name>Limit"` or `exception: "SaveTooLarge"` line.
fn limit_line(text: []const u8) ?usize {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var index: usize = 0;
    while (lines.next()) |line| : (index += 1) {
        if (!std.mem.startsWith(u8, line, "exception: \"")) continue;
        if (std.mem.endsWith(u8, line, "Limit\"")) return index;
        if (std.mem.eql(u8, line, "exception: \"SaveTooLarge\"")) return index;
    }
    return null;
}

test "limit_line finds inkz's limit errors and no other exception" {
    // A string that grows without end makes a save too large to load in a story's limits
    // (found by the swarm's differential run in P18.6).
    const expect = std.testing.expectEqual;
    try expect(@as(?usize, 1), limit_line("text: \"a\"\nexception: \"ThreadLimit\"\n"));
    try expect(@as(?usize, 0), limit_line("exception: \"SaveTooLarge\"\n"));
    try expect(@as(?usize, null), limit_line("exception: \"InvalidSave\"\n"));
    try expect(@as(?usize, null), limit_line("text: \"exception: \\\"Limit\\\"\"\n"));
}

/// The first `count` lines of `text`.
fn first_lines(text: []const u8, count: usize) []const u8 {
    var end: usize = 0;
    for (0..count) |_| {
        const newline = std.mem.indexOfScalarPos(u8, text, end, '\n') orelse return text;
        end = newline + 1;
    }
    return text[0..end];
}

fn case_path(
    arena: std.mem.Allocator,
    directory_path: []const u8,
    name: []const u8,
    extension: []const u8,
) ![]const u8 {
    assert(name.len > 0);
    return std.fmt.allocPrint(arena, "{s}/{s}{s}", .{ directory_path, name, extension });
}

fn without_bom(text: []const u8) []const u8 {
    const bom = "\xEF\xBB\xBF";
    return if (std.mem.startsWith(u8, text, bom)) text[bom.len..] else text;
}

pub const Summary = struct {
    cases: u32 = 0,
    timeouts: u32 = 0,
    harness_crashes: u32 = 0,
    pending: u32 = 0,
    ink_exceptions: u32 = 0,
    inkz_limits: u32 = 0,
    acceptance: u32 = 0,
    runtime: u32 = 0,
    pipeline: u32 = 0,
    structure: u32 = 0,

    pub fn divergences(summary: Summary) u32 {
        return summary.acceptance + summary.runtime + summary.pipeline + summary.structure;
    }
};

/// The names of the cases in `directory` (`<name>.ink`), sorted.
pub fn case_names(arena: std.mem.Allocator, io: std.Io, directory: std.Io.Dir) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".ink")) continue;
        try names.append(arena, try arena.dupe(u8, entry.name[0 .. entry.name.len - ".ink".len]));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    return names.items;
}

/// Checks every case in the directory at `path`, writes each divergence with its
/// configuration, and returns the counts.
pub fn check_directory(
    arena: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    replay: Replay,
    writer: *std.Io.Writer,
) !Summary {
    var directory = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer directory.close(io);
    var summary: Summary = .{};
    for (try case_names(arena, io, directory)) |name| {
        summary.cases += 1;
        const verdict = try check_case(arena, io, directory, path, name, replay);
        if (verdict.skipped) |skip| switch (skip) {
            .timeout => summary.timeouts += 1,
            .harness_crash => summary.harness_crashes += 1,
            .pending => summary.pending += 1,
            .ink_exception => summary.ink_exceptions += 1,
            .inkz_limit => summary.inkz_limits += 1,
        };
        if (!verdict.diverges()) continue;
        const swarm_line = try read_optional(arena, io, directory, name, ".swarm") orelse "";
        const configuration = swarm_line[0 .. std.mem.indexOfScalar(u8, swarm_line, '\n') orelse
            swarm_line.len];
        if (verdict.acceptance) |reason| {
            summary.acceptance += 1;
            try writer.print("{s}: compile acceptance: {s}\n", .{ name, reason });
        }
        if (verdict.runtime) |difference| {
            summary.runtime += 1;
            try writer.print("{s}: runtime: {s}\n", .{ name, difference });
        }
        if (verdict.pipeline) |difference| {
            summary.pipeline += 1;
            try writer.print("{s}: pipeline: {s}\n", .{ name, difference });
        }
        if (verdict.structure) {
            summary.structure += 1;
            try writer.print("{s}: structure: inkz's JSON differs from inklecate's\n", .{name});
        }
        try writer.print("  swarm: {s}\n", .{configuration});
    }
    try writer.print("{d} cases; not compared: {d} timeouts, {d} crashed ink, {d} without " ++
        "ink's results, {d} ink exceptions, {d} inkz limits; divergences: {d} compile " ++
        "acceptance, {d} runtime, {d} pipeline, {d} structure\n", .{
        summary.cases,      summary.timeouts,       summary.harness_crashes,
        summary.pending,    summary.ink_exceptions, summary.inkz_limits,
        summary.acceptance, summary.runtime,        summary.pipeline,
        summary.structure,
    });
    return summary;
}

// Tests.

const cases = @import("cases.zig");

test "generate writes the same files for the same seed" {
    const io = std.testing.io;
    var first = std.testing.tmpDir(.{ .iterate = true });
    defer first.cleanup();
    var second = std.testing.tmpDir(.{ .iterate = true });
    defer second.cleanup();
    try generate(io, first.dir, 7, 5, null);
    try generate(io, second.dir, 7, 5, null);
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const names = try case_names(arena, io, first.dir);
    try std.testing.expectEqual(@as(usize, 5), names.len);
    for (names) |name| {
        for ([_][]const u8{ ".ink", ".actions", ".swarm" }) |extension| {
            const a = (try read_optional(arena, io, first.dir, name, extension)).?;
            const b = (try read_optional(arena, io, second.dir, name, extension)).?;
            try std.testing.expectEqualStrings(a, b);
        }
    }
    const swarm_text = (try read_optional(arena, io, first.dir, "00000", ".swarm")).?;
    const line_end = std.mem.indexOfScalar(u8, swarm_text, '\n').?;
    _ = try Swarm.parse(swarm_text[0..line_end]);
}

test "check_directory reports each kind of divergence and passes a match" {
    // test/differential: a matching case, a changed transcript, a story only inkz compiles,
    // a JSON that plays the same but differs, and a timeout; copied to a temporary
    // directory, since the checker writes inkz's JSON next to each case.
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var fixtures = try std.Io.Dir.cwd().openDir(io, "test/differential", .{ .iterate = true });
    defer fixtures.close(io);
    var iterator = fixtures.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const data = try fixtures.readFileAlloc(io, entry.name, arena, .limited(file_bytes_max));
        try tmp.dir.writeFile(io, .{ .sub_path = entry.name, .data = data });
    }
    const path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var report: std.Io.Writer.Allocating = .init(arena);
    const summary = try check_directory(arena, io, path, cases.replay_json, &report.writer);
    const text = report.written();
    try std.testing.expectEqual(@as(u32, 5), summary.cases);
    try std.testing.expectEqual(@as(u32, 1), summary.timeouts);
    try std.testing.expectEqual(@as(u32, 1), summary.acceptance);
    try std.testing.expectEqual(@as(u32, 1), summary.runtime);
    try std.testing.expectEqual(@as(u32, 1), summary.structure);
    try std.testing.expectEqual(@as(u32, 0), summary.pipeline);
    try std.testing.expect(summary.divergences() > 0);
    try std.testing.expect(std.mem.indexOf(u8, text, "acceptance: compile acceptance") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "transcript: runtime") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "structure: structure") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "match:") == null);
    // Only the match: nothing diverges.
    var only = std.testing.tmpDir(.{ .iterate = true });
    defer only.cleanup();
    for ([_][]const u8{ ".ink", ".actions", ".ink.json", ".expected" }) |extension| {
        const name = try std.fmt.allocPrint(arena, "match{s}", .{extension});
        const data = try fixtures.readFileAlloc(io, name, arena, .limited(file_bytes_max));
        try only.dir.writeFile(io, .{ .sub_path = name, .data = data });
    }
    const only_path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{only.sub_path});
    report.clearRetainingCapacity();
    const clean = try check_directory(arena, io, only_path, cases.replay_json, &report.writer);
    try std.testing.expectEqual(@as(u32, 0), clean.divergences());
}
