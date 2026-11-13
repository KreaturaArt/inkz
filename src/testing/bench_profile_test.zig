//! Tests of the profile benchmark's records (`zig build bench-profile`).

const std = @import("std");
const bench_profile = @import("../bench_profile.zig");
const bench_io = @import("../bench_io.zig");
const profile = @import("../core/profile.zig");

test "records are the zones by exclusive time, then the time outside zones" {
    // Goal: the per-iteration figures and the outside time. Method: made-up totals for two
    // zones over 4 iterations and 10 µs of wall time.
    var totals: profile.Totals = .{};
    const parse = @backingInt(profile.Zone.compile_parse);
    const sema = @backingInt(profile.Zone.compile_sema);
    totals.calls[parse] = 4;
    totals.inclusive_ns[parse] = 6000;
    totals.exclusive_ns[parse] = 2000;
    totals.calls[sema] = 8;
    totals.inclusive_ns[sema] = 4000;
    totals.exclusive_ns[sema] = 4000;
    const measurement: bench_profile.Measurement = .{
        .workload = .compile,
        .iterations = 4,
        .wall_ns = 10_000,
        .totals = totals,
        .plain_ns_per_iteration = 2400,
    };
    const run: bench_io.Run = .{
        .timestamp = "2026-11-13T12:00:00Z",
        .commit = "abc",
        .dirty = false,
        .zig = "0.17.1",
        .mode = "fast",
        .target = "aarch64-macos",
        .cpu = "apple_m3",
    };
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const records = try bench_profile.records_of(arena_state.allocator(), run, "s", &measurement);
    try std.testing.expectEqual(@as(usize, 3), records.len);
    try std.testing.expectEqualStrings("compile_sema", records[0].zone);
    try std.testing.expectEqual(@as(f64, 1000), records[0].exclusive_ns_per_iteration);
    try std.testing.expectEqual(@as(f64, 2), records[0].calls_per_iteration);
    try std.testing.expectEqual(@as(f64, 0.4), records[0].share);
    try std.testing.expectEqualStrings("compile_parse", records[1].zone);
    try std.testing.expectEqual(@as(f64, 1500), records[1].inclusive_ns_per_iteration);
    try std.testing.expectEqualStrings("(outside zones)", records[2].zone);
    try std.testing.expectEqual(@as(f64, 1000), records[2].exclusive_ns_per_iteration);
    try std.testing.expectEqual(@as(f64, 2500), records[2].wall_ns_per_iteration);
    try std.testing.expectEqual(@as(f64, 2400), records[2].plain_wall_ns_per_iteration);
}
