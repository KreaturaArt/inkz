//! Tests of the load/store benchmark (`zig build bench-io`, TASK-152): its statistics, its
//! round-trip check and the JSON Lines record it appends.

const std = @import("std");
const assert = std.debug.assert;
const bench_io = @import("../bench_io.zig");
const compile = @import("../compiler/compile.zig");

test "the statistics are the sorted samples' minimum, median, mean and maximum" {
    var samples = [_]u64{ 9, 1, 8, 2, 7, 3, 6, 4, 5, 10, 100 };
    comptime assert(samples.len >= bench_io.samples_min);
    const stats = bench_io.stats_of(&samples);
    try std.testing.expectEqual(@as(u32, 11), stats.samples);
    try std.testing.expectEqual(@as(u64, 1), stats.min);
    try std.testing.expectEqual(@as(u64, 6), stats.median);
    try std.testing.expectEqual(@as(u64, 14), stats.mean);
    try std.testing.expectEqual(@as(u64, 100), stats.max);
}

test "a record is one JSON line with its sizes, times and throughput" {
    // Goal: the persisted format. Method: a compiled story's subject, a record of made-up
    // times, written as the bench writes it and parsed back.
    const gpa = std.testing.allocator;
    const source = "Hello\n* [Go] -> knot\n=== knot ===\nDone\n-> END\n";
    const json = try compile.compile_to_json(gpa, source);
    defer gpa.free(json);
    var subject: bench_io.Subject = try .init(gpa, json);
    defer subject.deinit(gpa);
    try subject.check_round_trips(gpa);
    const run: bench_io.Run = .{
        .timestamp = "2026-11-13T12:00:00Z",
        .commit = "abc",
        .dirty = false,
        .zig = "0.17.1",
        .mode = "safe",
        .target = "aarch64-macos",
        .cpu = "apple_m3",
    };
    const stats: bench_io.Stats = .{
        .samples = 10,
        .min = 500,
        .median = 1000,
        .mean = 1100,
        .max = 2000,
    };
    const record = bench_io.record_of(run, "hello", &subject, .image, .load, stats);
    try std.testing.expectEqual(@as(u64, subject.image.len), record.bytes);
    const expected_rate = @as(f64, @floatFromInt(subject.image.len)) / 1e6 / 1e-6;
    try std.testing.expectApproxEqRel(expected_rate, record.megabytes_per_second, 1e-9);
    var line: std.Io.Writer.Allocating = .init(gpa);
    defer line.deinit();
    try std.json.Stringify.value(record, .{}, &line.writer);
    try std.testing.expect(std.mem.indexOfScalar(u8, line.written(), '\n') == null);
    const parsed = try std.json.parseFromSlice(bench_io.Record, gpa, line.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(bench_io.Format.image, parsed.value.format);
    try std.testing.expectEqual(bench_io.Operation.load, parsed.value.operation);
    try std.testing.expectEqual(@as(u64, 1000), parsed.value.median_ns);
    try std.testing.expectEqualStrings("hello", parsed.value.story);
}
