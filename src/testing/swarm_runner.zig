//! `zig build swarm` (plan §3.7): seeded swarm runs out of the fuzzer, for long runs in
//! ReleaseSafe. Each seed draws a configuration and a generated story, and the target checks
//! it; every failure prints its configuration and the command that reproduces it, and the
//! run ends with the triage (`swarm_triage.zig`).

const std = @import("std");
const assert = std.debug.assert;
const fuzz_ink = @import("fuzz_ink.zig");
const triage_module = @import("swarm_triage.zig");
const compile = @import("../compiler/compile.zig");
const messages = @import("../compiler/messages.zig");
const api = @import("../runtime/story.zig");
const Swarm = fuzz_ink.Swarm;

pub const Target = enum {
    /// Compiles; a compiled program passes `Program.check` and compiles the same twice.
    compile,
    /// Compiles and plays with seeded choices; the state checks after every call.
    play,
    /// Plays, saves, loads the save into a fresh story, and saves again: the same save.
    save,
    /// Fails when glue is on and RANDOM is off: the runner's own test.
    synthetic,
};

/// What the runs reached, besides their failures: how many stories compiled, how far the
/// compiled ones played, and why the others didn't. Counting allocates nothing.
pub const Summary = struct {
    runs: u32 = 0,
    failures: u32 = 0,
    /// Sources that didn't compile, counted under their first error's code.
    compile_failures: u32 = 0,
    codes: Codes = .{},
    /// Played stories that reported an error (`on_error`) or stopped at one (`cont`,
    /// `choose_choice_index`).
    runtime_errors: u32 = 0,
    lines: u64 = 0,
    choices: u64 = 0,
    /// Played stories still going after `play_steps_max` calls.
    step_cap: u32 = 0,
    /// Played stories that ended before it without an error: at END or DONE, or with
    /// neither content nor choices left.
    ended: u32 = 0,

    pub fn format(summary: Summary, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{d} runs, {d} failures; compile failures {d}", .{
            summary.runs,
            summary.failures,
            summary.compile_failures,
        });
        try summary.codes.write_top(writer, 4);
        try writer.print("; runtime errors {d}, lines {d}, choices {d}, step cap {d}, " ++
            "ended {d}", .{
            summary.runtime_errors,
            summary.lines,
            summary.choices,
            summary.step_cap,
            summary.ended,
        });
    }
};

/// Compile failures by diagnostic code: the codes are the compiler's static names, so the
/// table keeps the slices; codes past its capacity count as `other`.
pub const Codes = struct {
    names: [capacity][]const u8 = undefined,
    counts: [capacity]u32 = undefined,
    len: u8 = 0,
    other: u32 = 0,

    const capacity = 16;

    fn add(codes: *Codes, name: []const u8, count: u32) void {
        assert(codes.len <= capacity);
        for (codes.names[0..codes.len], codes.counts[0..codes.len]) |known, *known_count| {
            if (std.mem.eql(u8, known, name)) {
                known_count.* += count;
                return;
            }
        }
        if (codes.len == capacity) {
            codes.other += count;
            return;
        }
        codes.names[codes.len] = name;
        codes.counts[codes.len] = count;
        codes.len += 1;
    }

    pub fn count_of(codes: *const Codes, name: []const u8) u32 {
        for (codes.names[0..codes.len], codes.counts[0..codes.len]) |known, count| {
            if (std.mem.eql(u8, known, name)) return count;
        }
        return 0;
    }

    /// ` (code n, code n, ...)` for the `top` most frequent codes, or nothing.
    fn write_top(codes: *const Codes, writer: *std.Io.Writer, top: u8) !void {
        if (codes.len == 0) return;
        var order: [capacity]u8 = undefined;
        for (order[0..codes.len], 0..) |*slot, index| slot.* = @intCast(index);
        const by_count = struct {
            fn more(counts: *const [capacity]u32, a: u8, b: u8) bool {
                return counts[a] > counts[b];
            }
        }.more;
        std.sort.insertion(u8, order[0..codes.len], &codes.counts, by_count);
        try writer.writeAll(" (");
        for (order[0..@min(top, codes.len)], 0..) |index, position| {
            if (position > 0) try writer.writeAll(", ");
            try writer.print("{s} {d}", .{ codes.names[index], codes.counts[index] });
        }
        if (codes.len > top or codes.other > 0) try writer.writeAll(", ...");
        try writer.writeByte(')');
    }
};

/// How long a run goes: `seeds` seeds, or fewer when `deadline` passes first.
pub const Budget = struct {
    seeds: u32,
    deadline: ?std.Io.Timestamp = null,
    io: ?std.Io = null,

    fn exhausted(budget: Budget) bool {
        const deadline = budget.deadline orelse return false;
        return std.Io.Timestamp.now(budget.io.?, .awake).nanoseconds >= deadline.nanoseconds;
    }
};

/// Runs seeds from `seed_first` on `target` within `budget`, writing failures and the triage.
pub fn run(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    target: Target,
    seed_first: u64,
    budget: Budget,
) !Summary {
    assert(budget.seeds > 0);
    assert((budget.deadline == null) == (budget.io == null));
    var summary: Summary = .{};
    var triage: triage_module.Triage = .{};
    for (0..budget.seeds) |offset| {
        if (offset > 0 and budget.exhausted()) break;
        const seed = seed_first + offset;
        var buffer: [fuzz_ink.source_bytes_max]u8 = undefined;
        const case = fuzz_ink.generate_case_seeded(seed, &buffer, .{});
        summary.runs += 1;
        const failure = try check_case(gpa, target, seed, case, &summary);
        triage.add(case.swarm, failure != null);
        const reason = failure orelse continue;
        summary.failures += 1;
        try writer.print("failure ({s}): seed {d}, swarm: {f}\nreproduce with: zig build swarm " ++
            "-Doptimize=ReleaseSafe -- --target {t} --seed {d} --seeds 1\n", .{
            reason, seed, case.swarm, target, seed,
        });
    }
    try writer.print("swarm {t}: {f}\n", .{ target, summary });
    try triage.report(writer);
    return summary;
}

/// Null when the seed's case passes; otherwise what failed.
fn check_case(
    gpa: std.mem.Allocator,
    target: Target,
    seed: u64,
    case: fuzz_ink.Generator.Case,
    summary: *Summary,
) !?[]const u8 {
    if (target == .synthetic) {
        const fails = case.swarm.lines.contains(.glue) and !case.swarm.terms.contains(.random);
        return if (fails) "synthetic" else null;
    }
    var first_error: ?[]const u8 = null;
    const sink: messages.Sink = .{ .context = &first_error, .function = keep_first_error };
    var program = compile.compile_source_with(gpa, case.source, .{
        .diagnostics = sink,
    }) catch |err| switch (err) {
        error.CompileFailed => {
            summary.compile_failures += 1;
            summary.codes.add(first_error orelse "none", 1);
            return null;
        },
        else => return err,
    };
    defer program.deinit(gpa);
    if (program.check() != .ok) return "Program.check";
    switch (target) {
        .compile => {
            var again = try compile.compile_source(gpa, case.source);
            defer again.deinit(gpa);
            if (again.instructions.len != program.instructions.len) return "not deterministic";
        },
        .play, .save => return play(gpa, &program, seed, target == .save, summary),
        .synthetic => unreachable,
    }
    return null;
}

fn keep_first_error(context: ?*anyopaque, diagnostic: messages.Diagnostic) void {
    const first: *?[]const u8 = @ptrCast(@alignCast(context.?));
    if (diagnostic.severity == .@"error" and first.* == null) first.* = diagnostic.code;
}

const Program = @import("../core/program.zig").Program;

/// The calls (`cont` or a choice) a played story gets.
const play_steps_max = 64;

fn note_error(context: ?*anyopaque, _: []const u8, severity: api.Severity) void {
    const errored: *bool = @ptrCast(@alignCast(context.?));
    if (severity == .@"error") errored.* = true;
}

fn play(
    gpa: std.mem.Allocator,
    program: *const Program,
    seed: u64,
    round_trip: bool,
    summary: *Summary,
) !?[]const u8 {
    var story: api.Story = undefined;
    try story.init(gpa, program, .{ .limits = .{ .steps_per_continue_max = 10_000 } });
    defer story.deinit(gpa);
    var errored = false;
    story.on_error = note_error;
    story.on_error_context = &errored;
    defer summary.runtime_errors += @intFromBool(errored);
    var prng: std.Random.DefaultPrng = .init(seed);
    const random = prng.random();
    var steps: u32 = 0;
    while (steps < play_steps_max) : (steps += 1) {
        if (story.can_continue()) {
            _ = story.cont() catch {
                errored = true;
                return null;
            };
            summary.lines += 1;
        } else {
            const count = story.current_choices_count();
            if (count == 0) break;
            const index = random.uintLessThan(u32, @intCast(count));
            story.choose_choice_index(index) catch {
                errored = true;
                return null;
            };
            summary.choices += 1;
        }
        if (story.state.check() != .ok) return "State.check";
    }
    if (steps == play_steps_max) summary.step_cap += 1;
    if (steps < play_steps_max and !errored) summary.ended += 1;
    if (!round_trip or story.failed) return null;
    var first: std.Io.Writer.Allocating = .init(gpa);
    defer first.deinit();
    try story.to_json(&first.writer);
    var loaded: api.Story = undefined;
    try loaded.init(gpa, program, .{ .limits = .{ .steps_per_continue_max = 10_000 } });
    defer loaded.deinit(gpa);
    loaded.load_json(first.written()) catch return "load of its own save";
    var second: std.Io.Writer.Allocating = .init(gpa);
    defer second.deinit();
    try loaded.to_json(&second.writer);
    if (!std.mem.eql(u8, first.written(), second.written())) return "save round trip";
    return null;
}

test "a failing swarm run prints the command that reproduces it, and the triage" {
    // The synthetic target fails on glue without RANDOM: each failure line carries its
    // configuration and the `zig build swarm` command for its seed, and the triage names
    // glue as the trigger (P16.6).
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const summary = try run(gpa, &out.writer, .synthetic, 100, .{ .seeds = 200 });
    try std.testing.expect(summary.failures > 0);
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "reproduce with: zig build swarm " ++
        "-Doptimize=ReleaseSafe -- --target synthetic --seed ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "trigger: lines.glue") != null);
    // The printed seed reproduces the failure alone.
    const at = std.mem.indexOf(u8, text, "--seed ").? + "--seed ".len;
    const end = std.mem.indexOfScalarPos(u8, text, at, ' ').?;
    const seed = try std.fmt.parseInt(u64, text[at..end], 10);
    var again: std.Io.Writer.Allocating = .init(gpa);
    defer again.deinit();
    const replayed = try run(gpa, &again.writer, .synthetic, seed, .{ .seeds = 1 });
    try std.testing.expectEqual(@as(u32, 1), replayed.failures);
}

test "the real targets pass a few seeds" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for ([_]Target{ .compile, .play, .save }) |target| {
        const summary = try run(gpa, &out.writer, target, 1, .{ .seeds = 8 });
        try std.testing.expectEqual(@as(u32, 0), summary.failures);
    }
}

test "the summary counts what the runs reached, and the run prints it" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const summary = try run(gpa, &out.writer, .play, 1, .{ .seeds = 16 });
    try std.testing.expect(summary.lines > 0);
    try std.testing.expect(summary.compile_failures + summary.runtime_errors <= summary.runs);
    var codes: u32 = summary.codes.other;
    for (summary.codes.counts[0..summary.codes.len]) |count| codes += count;
    try std.testing.expectEqual(summary.compile_failures, codes);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "swarm play: 16 runs, 0 failures; " ++
        "compile failures ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "step cap ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "ended ") != null);
}

test "played stories make many choices and reach the step cap, and some still end" {
    // P18.2: with `hub` and `typed`, the compiled stories of 500 seeds make 8 choices or
    // more on average, 35% or more reach the step cap, and 10% or more end (at END or DONE,
    // or out of content) without an error.
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const summary = try run(gpa, &out.writer, .play, 1, .{ .seeds = 500 });
    try std.testing.expectEqual(@as(u32, 0), summary.failures);
    const compiled = summary.runs - summary.compile_failures;
    try std.testing.expect(compiled > 400);
    try std.testing.expect(summary.choices >= 8 * @as(u64, compiled));
    try std.testing.expect(summary.step_cap * 100 >= compiled * 35);
    try std.testing.expect(summary.ended * 10 >= compiled);
}

test "codes keep the most frequent first, and count past their capacity as other" {
    var codes: Codes = .{};
    codes.add("b", 1);
    codes.add("a", 3);
    codes.add("b", 1);
    try std.testing.expectEqual(@as(u32, 2), codes.count_of("b"));
    var text: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&text);
    try codes.write_top(&writer, 4);
    try std.testing.expectEqualStrings(" (a 3, b 2)", writer.buffered());
    const names = [_][]const u8{ "c0", "c1", "c2", "c3", "c4", "c5", "c6", "c7", "c8", "c9" } ++
        [_][]const u8{ "d0", "d1", "d2", "d3", "d4" };
    for (names) |name| codes.add(name, 1);
    try std.testing.expectEqual(@as(u32, 1), codes.other);
}

test "a passed deadline stops the run after its first seed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const budget: Budget = .{ .seeds = 1000, .deadline = .now(io, .awake), .io = io };
    const summary = try run(gpa, &out.writer, .synthetic, 1, budget);
    try std.testing.expectEqual(@as(u32, 1), summary.runs);
}
