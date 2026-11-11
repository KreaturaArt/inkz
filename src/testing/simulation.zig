//! The deterministic story simulator (plan P0.9), run with `zig build simulate`. For each seed
//! it plays every ground-truth case with seeded random choices (`play_seeded <seed>`), each
//! run in its own process, and reports runs that crash. A run depends only on its engine,
//! case and seed, so every report carries the command that reproduces it.
//!
//! In P0 it drives the old runtime with random choices only. P5.12 enables the full action mix
//! (save/load points, flow switches, `evaluate_function`, `set_variable`, compact-always) and
//! `State.verify()` after every `cont()` on the new engine.

const std = @import("std");
const assert = std.debug.assert;
const build_options = @import("build_options");

pub const Outcome = enum { ok, crash };

pub const Run = struct {
    outcome: Outcome,
    transcript: []const u8,
};

/// Plays case `id` on `engine` with choices from `new Random(seed)`, in a child process.
pub fn run_seed(
    arena: std.mem.Allocator,
    io: std.Io,
    engine: []const u8,
    id: []const u8,
    seed: i32,
) !Run {
    assert(id.len > 0);
    assert(engine.len > 0);
    const actions = try std.fmt.allocPrint(arena, "play_seeded {d}", .{seed});
    const result = try std.process.run(arena, io, .{
        .argv = &.{ build_options.replay_case_path, engine, id, "--actions", actions },
        .stdout_limit = .limited(16 * 1024 * 1024),
        .stderr_limit = .limited(16 * 1024 * 1024),
    });
    const crashed = switch (result.term) {
        .exited => |code| code != 0,
        else => true,
    };
    const run: Run = .{ .outcome = if (crashed) .crash else .ok, .transcript = result.stdout };
    assert(run.outcome == .crash or run.transcript.len > 0);
    return run;
}

test "a simulation run is reproducible by seed" {
    // Goal: P0.9; the same engine, case and seed give the same run, and other seeds explore
    // other paths. Method: run a branching weave twice with one seed, then with others.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const id = "runtime/weaves/weave_gathers";
    const first = try run_seed(arena, io, "old", id, 7);
    const again = try run_seed(arena, io, "old", id, 7);
    try std.testing.expectEqual(Outcome.ok, first.outcome);
    try std.testing.expectEqualStrings(first.transcript, again.transcript);
    var differs = false;
    for ([_]i32{ 1, 2, 3, 4, 5, 6 }) |seed| {
        const other = try run_seed(arena, io, "old", id, seed);
        differs = differs or !std.mem.eql(u8, other.transcript, first.transcript);
    }
    try std.testing.expect(differs);
}
