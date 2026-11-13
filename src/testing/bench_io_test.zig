//! Tests of the load/store benchmark (`zig build bench-io`): the shared statistics, its
//! round-trip check and the JSON Lines record it appends.

const std = @import("std");
const bench_io = @import("../bench_io.zig");
const common = @import("../bench_common.zig");
const compile = @import("../compiler/compile.zig");

test "the statistics are the sorted samples' minimum, median, mean and maximum" {
    var samples = [_]u64{ 9, 1, 8, 2, 7, 3, 6, 4, 5, 10, 100 };
    const stats = common.stats_of(&samples);
    try std.testing.expectEqual(@as(u32, 11), stats.samples);
    try std.testing.expectEqual(@as(u64, 1), stats.min);
    try std.testing.expectEqual(@as(u64, 6), stats.median);
    try std.testing.expectEqual(@as(u64, 14), stats.mean);
    try std.testing.expectEqual(@as(u64, 100), stats.max);
    try std.testing.expectEqual(@as(u64, 155), stats.total);
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
    const stats: common.Stats = .{
        .samples = 10,
        .min = 500,
        .median = 1000,
        .mean = 1100,
        .max = 2000,
        .total = 11_000,
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

test "sampling warms up, then samples to the budget, within the minimum and maximum" {
    // Goal: the stopping rule. Method: a call that claims 100 ns, under three budgets.
    const Counter = struct {
        calls: u32 = 0,
        fn once(counter: *@This(), iteration: u32) !u64 {
            _ = iteration;
            counter.calls += 1;
            return 100;
        }
    };
    var buffer: [8]u64 = undefined;
    const sample = common.sample;
    var counter: Counter = .{};
    const no_budget: common.Sampling = .{ .warmup = 2, .samples_min = 3, .samples_max = 8 };
    try std.testing.expectEqual(3, (try sample(&counter, Counter.once, no_budget, &buffer)).len);
    try std.testing.expectEqual(5, counter.calls);
    var sampling: common.Sampling = .{ .samples_min = 3, .samples_max = 8 };
    sampling.budget_nanoseconds = 450;
    try std.testing.expectEqual(5, (try sample(&counter, Counter.once, sampling, &buffer)).len);
    sampling.budget_nanoseconds = 1_000_000;
    try std.testing.expectEqual(8, (try sample(&counter, Counter.once, sampling, &buffer)).len);
}
