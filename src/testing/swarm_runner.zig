//! `zig build swarm` (plan §3.7): seeded swarm runs out of the fuzzer, for long runs in
//! ReleaseSafe. Each seed draws a configuration and a generated story, and the target checks
//! it; every failure prints its configuration and the command that reproduces it, and the
//! run ends with the triage (`swarm_triage.zig`).

const std = @import("std");
const assert = std.debug.assert;
const fuzz_ink = @import("fuzz_ink.zig");
const triage_module = @import("swarm_triage.zig");
const compile = @import("../compiler/compile.zig");
const api = @import("../runtime/api.zig");
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

pub const Summary = struct { runs: u32 = 0, failures: u32 = 0 };

/// Runs `seeds` seeds from `seed_first` on `target`, writing failures and the triage.
pub fn run(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    target: Target,
    seed_first: u64,
    seeds: u32,
) !Summary {
    assert(seeds > 0);
    var summary: Summary = .{};
    var triage: triage_module.Triage = .{};
    for (0..seeds) |offset| {
        const seed = seed_first + offset;
        var buffer: [fuzz_ink.source_bytes_max]u8 = undefined;
        const case = fuzz_ink.generate_case_seeded(seed, &buffer, .{});
        summary.runs += 1;
        const failure = try check_case(gpa, target, seed, case);
        triage.add(case.swarm, failure != null);
        const reason = failure orelse continue;
        summary.failures += 1;
        try writer.print("failure ({s}): seed {d}, swarm: {f}\nreproduce with: zig build swarm " ++
            "-Doptimize=ReleaseSafe -- --target {t} --seed {d} --seeds 1\n", .{
            reason, seed, case.swarm, target, seed,
        });
    }
    try writer.print("swarm {t}: {d} runs, {d} failures\n", .{
        target,
        summary.runs,
        summary.failures,
    });
    try triage.report(writer);
    return summary;
}

/// Null when the seed's case passes; otherwise what failed.
fn check_case(
    gpa: std.mem.Allocator,
    target: Target,
    seed: u64,
    case: fuzz_ink.Generator.Case,
) !?[]const u8 {
    if (target == .synthetic) {
        const fails = case.swarm.lines.contains(.glue) and !case.swarm.terms.contains(.random);
        return if (fails) "synthetic" else null;
    }
    var program = compile.compile_source(gpa, case.source) catch |err| switch (err) {
        error.CompileFailed => return null,
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
        .play, .save => return play(gpa, &program, seed, target == .save),
        .synthetic => unreachable,
    }
    return null;
}

const Program = @import("../core/program.zig").Program;

fn play(gpa: std.mem.Allocator, program: *const Program, seed: u64, round_trip: bool) !?[]const u8 {
    var story: api.Story = undefined;
    try story.init(gpa, program, .{ .limits = .{ .steps_per_continue_max = 10_000 } });
    defer story.deinit(gpa);
    story.core.on_error = @import("support.zig").ignore_message;
    var prng: std.Random.DefaultPrng = .init(seed);
    const random = prng.random();
    for (0..64) |_| {
        if (story.can_continue()) {
            _ = story.cont() catch return null;
        } else {
            const count = story.current_choices_count();
            if (count == 0) break;
            story.choose_choice_index(random.uintLessThan(u32, @intCast(count))) catch return null;
        }
        if (story.core.state.check() != .ok) return "State.check";
    }
    if (!round_trip or story.core.failed) return null;
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
    const summary = try run(gpa, &out.writer, .synthetic, 100, 200);
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
    const replayed = try run(gpa, &again.writer, .synthetic, seed, 1);
    try std.testing.expectEqual(@as(u32, 1), replayed.failures);
}

test "the real targets pass a few seeds" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for ([_]Target{ .compile, .play, .save }) |target| {
        const summary = try run(gpa, &out.writer, target, 1, 8);
        try std.testing.expectEqual(@as(u32, 0), summary.failures);
    }
}
