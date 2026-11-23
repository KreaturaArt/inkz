//! `zig build test-profile`: the profile zones with profiling compiled in, which a
//! test can't do (a test's root is the test runner, not this file). Exits with an error when a
//! check fails.

const std = @import("std");
const assert = std.debug.assert;
const profile = @import("core/profile.zig");

pub const inkz_profile = true;

fn spin(rounds: u32) u64 {
    assert(rounds > 0);
    var sum: u64 = 0;
    for (0..rounds) |round| sum +%= std.hash.int(@as(u64, round));
    std.mem.doNotOptimizeAway(sum);
    assert(rounds > 0);
    return sum;
}

/// Nested zones: the inner zone's time is in the outer's inclusive time and out of its
/// exclusive time.
fn check_nesting() !void {
    assert(!profile.active);
    profile.active = true;
    defer profile.active = false;
    profile.reset();
    for (0..100) |_| {
        const outer = profile.begin(.compile_parse);
        _ = spin(1000);
        for (0..3) |_| {
            const inner = profile.begin(.compile_comments);
            _ = spin(1000);
            inner.end();
        }
        outer.end();
    }
    const totals = profile.totals();
    const outer = @backingInt(profile.Zone.compile_parse);
    const inner = @backingInt(profile.Zone.compile_comments);
    try std.testing.expectEqual(@as(u64, 100), totals.calls[outer]);
    try std.testing.expectEqual(@as(u64, 300), totals.calls[inner]);
    try std.testing.expect(totals.inclusive_ns[inner] == totals.exclusive_ns[inner]);
    try std.testing.expect(totals.inclusive_ns[outer] > totals.inclusive_ns[inner]);
    // Exclusive plus the children's inclusive is the inclusive time (to rounding).
    const sum = totals.exclusive_ns[outer] + totals.inclusive_ns[inner];
    try std.testing.expect(@max(sum, totals.inclusive_ns[outer]) -
        @min(sum, totals.inclusive_ns[outer]) <= 2);
    try std.testing.expect(totals.exclusive_ns[outer] > 0);
    assert(profile.active);
}

/// With `active` off, zones record nothing.
fn check_inactive() !void {
    assert(!profile.active);
    profile.reset();
    const zone = profile.begin(.vm_run);
    _ = spin(100);
    zone.end();
    const totals = profile.totals();
    try std.testing.expectEqual(@as(u64, 0), totals.calls[@backingInt(profile.Zone.vm_run)]);
    assert(!profile.active);
}

/// The counter's rate matches the system clock: a 20 ms busy wait measures 20 ms, and no
/// more than the system clock saw around the zone (a shared CI machine may preempt the
/// thread inside it, which lengthens both).
fn check_rate(io: std.Io) !void {
    assert(!profile.active);
    profile.active = true;
    defer profile.active = false;
    profile.reset();
    const before = std.Io.Timestamp.now(io, .awake);
    const zone = profile.begin(.cont);
    const start = std.Io.Timestamp.now(io, .awake);
    while (start.durationTo(std.Io.Timestamp.now(io, .awake)).toNanoseconds() < 20_000_000) {}
    zone.end();
    const after = std.Io.Timestamp.now(io, .awake);
    const around: u64 = @intCast(before.durationTo(after).toNanoseconds());
    const measured = profile.totals().inclusive_ns[@backingInt(profile.Zone.cont)];
    try std.testing.expect(measured > 19_000_000);
    try std.testing.expect(measured < around + around / 10);
    assert(around >= 20_000_000);
}

/// The zones the F15 and F18 decisions read (docs/benchmarks.md): a play with arithmetic
/// records `call_native`, and loading a save records its parse and its pass.
fn check_runtime_zones() !void {
    assert(!profile.active);
    const api = @import("runtime/story.zig");
    const gpa = std.heap.page_allocator;
    var story: api.Story = undefined;
    const json = "{\"inkVersion\":21,\"root\":[[\"ev\",1,2,\"+\",\"out\",\"/ev\",\"\\n\"," ++
        "[\"done\",{\"#n\":\"g-0\"}],null],\"done\",null],\"listDefs\":{}}";
    try story.init_from_json(gpa, json, .{});
    defer story.deinit(gpa);
    profile.active = true;
    defer profile.active = false;
    profile.reset();
    try std.testing.expectEqualStrings("3\n", (try story.cont()).get());
    var save: std.Io.Writer.Allocating = .init(gpa);
    defer save.deinit();
    try story.to_json(&save.writer);
    try story.load_json(save.written());
    const totals = profile.totals();
    for ([_]profile.Zone{ .call_native, .load_parse, .load_commit }) |zone| {
        try std.testing.expect(totals.calls[@backingInt(zone)] > 0);
    }
    assert(profile.active);
}

pub fn main(init: std.process.Init) !void {
    comptime assert(profile.enabled);
    assert(!profile.active);
    profile.start(init.io, 20_000_000);
    try check_nesting();
    try check_inactive();
    try check_rate(init.io);
    try check_runtime_zones();
    std.debug.print("profile zones: nesting, inactive, rate and runtime zone checks pass\n", .{});
}
