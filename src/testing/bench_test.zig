//! Tests of the benchmarks (src/bench.zig): the command line, the sampling and its
//! statistics, the workload table, the JSON Lines records (and the committed history's) and
//! the report's marked sections.

const std = @import("std");
const bench = @import("../bench.zig");
const compile = @import("../compiler/compile.zig");
const profile = @import("../core/profile.zig");

test {
    // The subcommands compile, though only the bench binaries run them.
    _ = &bench.main;
}

test "the command line names a subcommand, and --record only for io and profile" {
    // The committed history in bench/ only grows when a run is started with --record.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = try bench.Arguments.parse(&.{"io"});
    try std.testing.expectEqual(bench.Command.io, io.command);
    try std.testing.expectEqualStrings(
        "zig-out/bench/load_store.jsonl",
        try io.path(arena, "load_store.jsonl"),
    );
    const record = try bench.Arguments.parse(&.{ "profile", "--record" });
    try std.testing.expectEqual(bench.Command.profile, record.command);
    try std.testing.expectEqualStrings(
        "bench/profile.jsonl",
        try record.path(arena, "profile.jsonl"),
    );
    try std.testing.expect(!(try bench.Arguments.parse(&.{"runtime"})).record);
    const bad = [_][]const []const u8{
        &.{},
        &.{"benchmark"},
        &.{ "io", "--recrod" },
        &.{ "io", "--record", "x" },
        &.{ "runtime", "--record" },
    };
    for (bad) |arguments| {
        try std.testing.expectError(error.BadArguments, bench.Arguments.parse(arguments));
    }
}

test "the statistics are the sorted samples' minimum, median, mean and maximum" {
    var samples = [_]u64{ 9, 1, 8, 2, 7, 3, 6, 4, 5, 10, 100 };
    const stats = bench.stats_of(&samples);
    try std.testing.expectEqual(@as(u32, 11), stats.samples);
    try std.testing.expectEqual(@as(u64, 1), stats.min);
    try std.testing.expectEqual(@as(u64, 6), stats.median);
    try std.testing.expectEqual(@as(u64, 14), stats.mean);
    try std.testing.expectEqual(@as(u64, 100), stats.max);
    try std.testing.expectEqual(@as(u64, 155), stats.total);
}

test "sampling warms up, then samples to the budget, within the minimum and maximum" {
    // The stopping rule: a call that claims 100 ns, under three budgets.
    const Counter = struct {
        calls: u32 = 0,
        fn once(counter: *@This(), iteration: u32) !u64 {
            _ = iteration;
            counter.calls += 1;
            return 100;
        }
    };
    var buffer: [8]u64 = undefined;
    const sample = bench.sample;
    var counter: Counter = .{};
    const no_budget: bench.Sampling = .{ .warmup = 2, .samples_min = 3, .samples_max = 8 };
    const counted = try sample(&counter, Counter.once, no_budget, &buffer);
    try std.testing.expectEqual(3, counted.samples);
    try std.testing.expectEqual(5, counter.calls);
    var sampling: bench.Sampling = .{ .samples_min = 3, .samples_max = 8 };
    sampling.budget_nanoseconds = 450;
    try std.testing.expectEqual(5, (try sample(&counter, Counter.once, sampling, &buffer)).samples);
    sampling.budget_nanoseconds = 1_000_000;
    try std.testing.expectEqual(8, (try sample(&counter, Counter.once, sampling, &buffer)).samples);
}

const source = "VAR x = 1\nHello {x + 1}\n* [Go] -> knot\n* [Stay] Stayed.\n-> END\n" ++
    "=== knot ===\nDone\n-> END\n";

test "every workload runs on a story's inputs; the io ones are format and operation pairs" {
    // The workload table: each workload once on a small compiled story, whose JSON and image
    // round-trip; `play` counts what it played.
    const gpa = std.testing.allocator;
    const json = try compile.compile_to_json(gpa, source);
    defer gpa.free(json);
    var inputs: bench.Inputs = undefined;
    try inputs.prepare(gpa, std.testing.io, source, json, .{});
    defer inputs.deinit();
    for (std.enums.values(bench.Workload), 0..) |workload, iteration| {
        _ = try inputs.run(workload, @intCast(iteration));
    }
    try std.testing.expectEqual(@as(u64, 2), inputs.lines);
    try std.testing.expectEqual(@as(u64, 1), inputs.turns);
    const Pair = struct { bench.Format, bench.Operation };
    const pairs = [_]Pair{
        .{ .json, .load },   .{ .json, .store },         .{ .image, .load },
        .{ .image, .store }, .{ .image_trusted, .load },
    };
    for (bench.Workload.io, pairs) |workload, pair| {
        try std.testing.expectEqual(pair, Pair{ workload.io_format(), workload.io_operation() });
    }
}

test "a record is one JSON line: the run, the story, then the measurement's fields" {
    // The persisted format: a load/store record of made-up times on a compiled story's
    // inputs, written as the bench writes it and parsed back.
    const gpa = std.testing.allocator;
    const json = try compile.compile_to_json(gpa, source);
    defer gpa.free(json);
    var inputs: bench.Inputs = undefined;
    try inputs.prepare(gpa, std.testing.io, source, json, .{});
    defer inputs.deinit();
    const run: bench.Run = .{
        .timestamp = "2026-11-13T12:00:00Z",
        .commit = "abc",
        .dirty = false,
        .zig = "0.17.1",
        .mode = "safe",
        .target = "aarch64-macos",
        .cpu = "apple_m3",
    };
    const stats: bench.Stats = .{
        .samples = 10,
        .min = 500,
        .median = 1000,
        .mean = 1100,
        .max = 2000,
        .total = 11_000,
    };
    const record = bench.load_store_of(&inputs, .image_load, stats);
    try std.testing.expectEqual(@as(u64, inputs.image.len), record.bytes);
    const expected_rate = @as(f64, @floatFromInt(inputs.image.len)) / 1e6 / 1e-6;
    try std.testing.expectApproxEqRel(expected_rate, record.megabytes_per_second, 1e-9);
    var line: std.Io.Writer.Allocating = .init(gpa);
    defer line.deinit();
    try bench.write_record(&line.writer, run, "hello", record);
    const written = line.written();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, written, "\n"));
    const start = "{\"timestamp\":\"2026-11-13T12:00:00Z\"";
    try std.testing.expect(std.mem.startsWith(u8, written, start));
    const story = "\"story\":\"hello\",\"format\":\"image\"";
    try std.testing.expect(std.mem.indexOf(u8, written, story) != null);
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    const parsed = try std.json.parseFromSlice(bench.LoadStore, gpa, written, options);
    defer parsed.deinit();
    try std.testing.expectEqual(bench.Format.image, parsed.value.format);
    try std.testing.expectEqual(bench.Operation.load, parsed.value.operation);
    try std.testing.expectEqual(@as(u64, 1000), parsed.value.median_ns);
    const parsed_run = try std.json.parseFromSlice(bench.Run, gpa, written, options);
    defer parsed_run.deinit();
    try std.testing.expectEqualStrings("abc", parsed_run.value.commit);
}

test "the committed history's records parse as a run and a measurement" {
    // A line of each of bench/load_store.jsonl and bench/profile.jsonl, as recorded.
    const gpa = std.testing.allocator;
    const load_store = "{\"timestamp\":\"2026-11-13T08:34:15Z\",\"commit\":\"a45c19b06ad8\"," ++
        "\"dirty\":false,\"zig\":\"0.17.1\",\"mode\":\"safe\",\"target\":\"aarch64-macos\"," ++
        "\"cpu\":\"apple_m3\",\"story\":\"crime_scene\",\"format\":\"json\",\"operation\":" ++
        "\"load\",\"bytes\":26635,\"samples\":500,\"min_ns\":247708,\"median_ns\":268083," ++
        "\"mean_ns\":275627,\"max_ns\":435791,\"megabytes_per_second\":99.35355841287958}";
    const zones = "{\"timestamp\":\"2026-11-13T09:09:47Z\",\"commit\":\"8640770d166f\"," ++
        "\"dirty\":false,\"zig\":\"0.17.1\",\"mode\":\"fast\",\"target\":\"aarch64-macos\"," ++
        "\"cpu\":\"apple_m3\",\"story\":\"crime_scene\",\"workload\":\"compile\",\"zone\":" ++
        "\"compile_parse\",\"iterations\":2100,\"wall_ns_per_iteration\":476245.53571428574," ++
        "\"plain_wall_ns_per_iteration\":475437.26235741447,\"calls_per_iteration\":1," ++
        "\"exclusive_ns_per_iteration\":134592.74142857143,\"inclusive_ns_per_iteration\":" ++
        "145240.10428571427,\"share\":0.2826120799782525}";
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    for ([_][]const u8{ load_store, zones }) |line| {
        const run = try std.json.parseFromSlice(bench.Run, gpa, line, options);
        defer run.deinit();
        try std.testing.expectEqualStrings("apple_m3", run.value.cpu);
    }
    const io = try std.json.parseFromSlice(bench.LoadStore, gpa, load_store, options);
    defer io.deinit();
    try std.testing.expectEqual(@as(u64, 268083), io.value.median_ns);
    const zone = try std.json.parseFromSlice(bench.ZoneTime, gpa, zones, options);
    defer zone.deinit();
    try std.testing.expectEqual(bench.Workload.compile, zone.value.workload);
    try std.testing.expectEqualStrings("compile_parse", zone.value.zone);
}

test "zone records are the zones by exclusive time, then the time outside zones" {
    // The per-iteration figures and the outside time: made-up totals for two
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
    const profiled: bench.Profiled = .{
        .workload = .compile,
        .iterations = 4,
        .wall_ns = 10_000,
        .totals = totals,
        .plain_ns_per_iteration = 2400,
    };
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const records = try bench.zone_times_of(arena_state.allocator(), &profiled);
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

test "a report section is replaced between its markers, or appended" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const mode = @import("builtin").mode;
    const appended = try bench.replace_section(arena, "# Report\n", "bench-x", "X", "old\n");
    const expected = try std.fmt.allocPrint(
        arena,
        "# Report\n\n<!-- bench-x:{t}:start -->\n### X, {t}\n\nold\n<!-- bench-x:{t}:end -->\n",
        .{ mode, mode, mode },
    );
    try std.testing.expectEqualStrings(expected, appended);
    const report = try std.mem.concat(arena, u8, &.{ appended, "after\n" });
    const replaced = try bench.replace_section(arena, report, "bench-x", "X", "new\n");
    try std.testing.expect(std.mem.indexOf(u8, replaced, "old") == null);
    try std.testing.expect(std.mem.endsWith(u8, replaced, "new\n" ++ "<!-- bench-x:" ++
        @tagName(mode) ++ ":end -->\nafter\n"));
}
