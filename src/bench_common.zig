//! What the benchmarks (`bench`, `bench-io`, `bench-profile`) share: a timer, a sampling
//! loop with its statistics, the seeded play and an error handler that ignores errors.

const std = @import("std");
const assert = std.debug.assert;
const Story = @import("runtime/story.zig").Story;
const Severity = @import("runtime/state.zig").Diagnostic.Severity;
const DotnetRandom = @import("core/dotnet_random.zig").DotnetRandom;

/// The awake clock since `begin`.
pub const Timer = struct {
    started: std.Io.Timestamp,

    pub fn begin(io: std.Io) Timer {
        return .{ .started = .now(io, .awake) };
    }

    pub fn nanoseconds(timer: Timer, io: std.Io) u64 {
        const elapsed = timer.started.durationTo(.now(io, .awake)).toNanoseconds();
        assert(elapsed >= 0);
        return @intCast(elapsed);
    }
};

/// How long `sample` keeps sampling: `warmup` untimed calls, then samples until there are
/// `samples_min` and either `budget_nanoseconds` of them or `samples_max`.
pub const Sampling = struct {
    warmup: u32 = 0,
    samples_min: u32,
    samples_max: u32,
    budget_nanoseconds: u64 = 0,
};

/// Calls `once(context, iteration)` as `sampling` says; each call returns the nanoseconds
/// it timed, so it can leave set-up and clean-up out. Returns the samples, in `buffer`.
pub fn sample(
    context: anytype,
    comptime once: fn (@TypeOf(context), u32) anyerror!u64,
    sampling: Sampling,
    buffer: []u64,
) ![]u64 {
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
    return buffer[0..count];
}

pub const Stats = struct { samples: u32, min: u64, median: u64, mean: u64, max: u64, total: u64 };

/// Sorts `samples` and returns their statistics.
pub fn stats_of(samples: []u64) Stats {
    assert(samples.len > 0);
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

/// The longest play, in turns.
pub const turns_max = 200;

pub const Played = struct { turns: u32, lines: u32 };

/// One play from the start: every line, then a choice by .NET Random seeded with `seed`,
/// until there are no choices or `turns_max` turns have passed.
pub fn play(story: *Story, seed: u32) !Played {
    assert(seed > 0);
    try story.reset_state();
    var random = DotnetRandom.init(@intCast(seed));
    var played: Played = .{ .turns = 0, .lines = 0 };
    while (played.turns < turns_max) : (played.turns += 1) {
        while (story.can_continue()) {
            _ = try story.cont();
            played.lines += 1;
        }
        const count = story.visible_choices_count();
        if (count == 0) break;
        try story.choose_choice_index(@intCast(@mod(random.next(), @as(i32, @intCast(count)))));
    }
    return played;
}

/// An `on_error` handler for plays whose errors don't matter to the measurement.
pub fn ignore_errors(context: ?*anyopaque, message: []const u8, severity: Severity) void {
    _ = context;
    _ = message;
    _ = severity;
}
