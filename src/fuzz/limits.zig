//! Fuzz target for the runtime's limits (plan §3.5, a limits swarm): a generated story
//! played by a host call mix under limits drawn field by field, each its default or tight
//! (a few of what a story needs, heap bytes down to a few hundred). Every call returns a
//! result or an error, the state checks after each one, and a story that failed in the
//! middle of a step stays failed (`error.StoryFailed`) until `reset_state` or `load_json`.
//! With `compact_always` drawn, the heap compacts at every reservation of room.
//!
//! The budget property: a run's peak usage, fitted with no margin (`Limits.fitted(usage,
//! 1)`), is enough to replay the same run without a limit error.

const std = @import("std");
const assert = std.debug.assert;
const fuzz_ink = @import("../testing/fuzz_ink.zig");
const play = @import("play.zig");
const host = @import("host.zig");
const limits_module = @import("../core/limits.zig");
const Limits = limits_module.Limits;

const calls_max = 48;

/// A tight value for a limit: a byte count of a few hundred to a few thousand (the save
/// scratch 1 to 64 KiB), or a count of 1 to 16 (4 to 64 for the counts a story needs many
/// of to start at all).
fn tight(choices: fuzz_ink.Choices, comptime name: []const u8) u32 {
    if (comptime std.mem.eql(u8, name, "load_bytes_max")) {
        return std.mem.alignForward(u32, choices.range(u32, 1024, 64 * 1024), 8);
    }
    if (comptime std.mem.endsWith(u8, name, "bytes_max")) {
        return std.mem.alignForward(u32, choices.range(u32, 256, 4096), 4);
    }
    const roomy = comptime std.mem.eql(u8, name, "steps_per_continue_max") or
        std.mem.eql(u8, name, "container_depth_max") or
        std.mem.eql(u8, name, "path_components_max");
    if (roomy) return choices.range(u32, 64, 4096);
    return choices.range(u32, 1, 16);
}

/// Each field its default or, with probability ½, tight; then the cross-field rules of
/// `Limits.check` restored (the way `Limits.fitted` does).
pub fn draw_limits(choices: fuzz_ink.Choices) Limits {
    return draw_limits_with(choices, false);
}

/// `draw_limits`, or with `all_tight` every field tight.
fn draw_limits_with(choices: fuzz_ink.Choices, all_tight: bool) Limits {
    var limits: Limits = .{ .steps_per_continue_max = 10_000 };
    inline for (@typeInfo(Limits).@"struct".field_names) |name| {
        if (all_tight or choices.choose(bool)) @field(limits, name) = tight(choices, name);
    }
    limits.output_bytes_max = @max(limits.output_bytes_max, limits.output_items_max);
    limits.frames_max = @max(limits.frames_max, limits.threads_max, limits.evaluate_depth_max);
    limits.temps_per_frame_max = @min(limits.temps_per_frame_max, limits.temps_max);
    limits.choice_snapshot_frames_max = @min(
        limits.choice_snapshot_frames_max,
        limits.frames_max * limits.choices_max,
    );
    assert(limits.check() == .ok);
    return limits;
}

/// The errors of one session, in order, for comparing two runs.
const Errors = struct {
    names: [calls_max][]const u8 = undefined,
    count: u32 = 0,
    limits: u32 = 0,

    fn add(errors: *Errors, err: anyerror) void {
        assert(errors.count < calls_max);
        errors.names[errors.count] = @errorName(err);
        errors.count += 1;
        if (std.mem.endsWith(u8, @errorName(err), "Limit")) errors.limits += 1;
    }

    fn eql(a: *const Errors, b: *const Errors) bool {
        if (a.count != b.count) return false;
        for (a.names[0..a.count], b.names[0..b.count]) |x, y| {
            if (!std.mem.eql(u8, x, y)) return false;
        }
        return true;
    }
};

const Session = struct {
    errors: Errors = .{},
    usage: limits_module.Usage = .{},
};

/// A generated story and a host call mix on it under `limits`; null when the story doesn't
/// compile or the limits can't hold it.
fn session(choices: fuzz_ink.Choices, limits: Limits, compact_always: bool) !?Session {
    const gpa = std.testing.allocator;
    var buffer: [fuzz_ink.source_bytes_max]u8 = undefined;
    var program = try play.compile_story(gpa, choices, &buffer) orelse return null;
    defer program.deinit(gpa);
    var story: play.Story = undefined;
    play.init_story_with(&story, gpa, &program, .pick(choices), limits) catch |err|
        switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
    defer story.deinit(gpa);
    story.state.compact_always = compact_always;
    const calls = host.draw_calls(choices);
    var kept: ?play.Value = null;
    var result: Session = .{};
    var count: u32 = 0;
    while (count < calls_max and choices.more(7, 1)) : (count += 1) {
        _ = host.call(gpa, &story, choices, &kept, calls) catch |err| {
            result.errors.add(err);
            // A story that failed in the middle of a step stays failed.
            if (story.failed) assert(story.cont() == error.StoryFailed);
        };
        assert(story.state.check() == .ok);
    }
    result.usage = story.usage();
    return result;
}

/// A session on drawn limits; whether it played.
fn limits_swarm(choices: fuzz_ink.Choices) !bool {
    const limits = draw_limits(choices);
    return try session(choices, limits, choices.choose(bool)) != null;
}

/// The budget property for the run seeded with `seed`: replayed under its fitted limits, it
/// makes the same calls with the same errors. Whether the run was a story that compiled
/// and hit no limit (the others say nothing about the budget).
fn check_budget(seed: u64) !bool {
    const default_limits: Limits = .{ .steps_per_continue_max = 10_000 };
    var prng: std.Random.DefaultPrng = .init(seed);
    const first = try session(.{ .random = prng.random() }, default_limits, false) orelse
        return false;
    if (first.errors.limits > 0) return false;
    var fitted = limits_module.fitted(first.usage, 1);
    fitted.steps_per_continue_max = default_limits.steps_per_continue_max;
    prng = .init(seed);
    const second = (try session(.{ .random = prng.random() }, fitted, false)).?;
    if (!first.errors.eql(&second.errors)) {
        std.debug.print("seed {d}: fitted limits changed the run\n", .{seed});
        for (first.errors.names[0..first.errors.count]) |name| std.debug.print(" {s}", .{name});
        std.debug.print("\n", .{});
        for (second.errors.names[0..second.errors.count]) |name| std.debug.print(" {s}", .{name});
        std.debug.print("\n", .{});
        return error.BudgetTooSmall;
    }
    return true;
}

test "fuzz: limits drawn tight or default fail cleanly" {
    // Seeded sessions first: the limits are drawn per field, and some sessions have
    // tight limits and still play.
    try fuzz_ink.run_target(limits_swarm, 8);
}

test "fuzz: a run's fitted usage replays it without a limit error" {
    // The budget property on 50 seeded stories (those that compile and hit no limit): each
    // replays with the same errors under Limits.fitted(usage, 1).
    var checked: u32 = 0;
    var seed: u64 = 0;
    while (checked < 50) : (seed += 1) {
        try std.testing.expect(seed < 400);
        if (try check_budget(seed)) checked += 1;
    }
}

test "fuzz: every limit tight still fails cleanly" {
    // Seeded stories with every limit tight: the sessions that start return errors, the
    // state checks after every call (in `session`), and some calls hit a named limit.
    var limit_errors: u32 = 0;
    var started: u32 = 0;
    for (0..64) |seed| {
        var prng: std.Random.DefaultPrng = .init(seed);
        const choices: fuzz_ink.Choices = .{ .random = prng.random() };
        const limits = draw_limits_with(choices, true);
        const result = try session(choices, limits, choices.choose(bool)) orelse continue;
        started += 1;
        limit_errors += result.errors.limits;
    }
    try std.testing.expect(started > 0);
    try std.testing.expect(limit_errors > 0);
}

test "fuzz: drawn limits are valid and some are tight" {
    var tight_heaps: u32 = 0;
    for (0..256) |seed| {
        var prng: std.Random.DefaultPrng = .init(seed);
        const limits = draw_limits(.{ .random = prng.random() });
        try std.testing.expect(limits.check() == .ok);
        if (limits.heap_bytes_max <= 4096) tight_heaps += 1;
    }
    try std.testing.expect(tight_heaps > 64 and tight_heaps < 192);
}
