//! The new loader against the old one (plan P3.1): peak memory while loading the full stories.

const std = @import("std");
const assert = std.debug.assert;
const ink_json = @import("../core/ink_json.zig");
const CountingAllocator = @import("../core/counting_allocator.zig").CountingAllocator;
const Story = @import("../runtime/story.zig").Story;

const PeakBytes = struct { new: u64, old: u64 };

fn measure(path: []const u8) !PeakBytes {
    assert(std.mem.endsWith(u8, path, ".ink.json"));
    assert(path.len > 0);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const json = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 24));
    defer gpa.free(json);
    var new_counting = CountingAllocator.init(gpa);
    var program = try ink_json.load(new_counting.allocator(), json);
    program.deinit(new_counting.allocator());
    var old_counting = CountingAllocator.init(gpa);
    var story = try Story.initFromJson(old_counting.allocator(), json);
    story.deinit();
    assert(new_counting.bytes_live == 0);
    return .{ .new = new_counting.bytes_peak, .old = old_counting.bytes_peak };
}

test "the new loader peaks below the old one" {
    // Goal: P3.1. Method: load the two full stories with both loaders behind counting
    // allocators and compare the peaks.
    const stories = [_][]const u8{
        "test/ground_truth/crime_scene.ink.json",
        "test/ground_truth/simple_taster_tutorial.ink.json",
    };
    for (stories) |path| {
        const peak = try measure(path);
        std.debug.print("{s}: new loader peak {d} B, old loader peak {d} B\n", .{
            path,
            peak.new,
            peak.old,
        });
        try std.testing.expect(peak.new < peak.old);
    }
}

const Program = @import("../core/program.zig").Program;
const ink_path = @import("../core/path.zig");

/// The old runtime's containers and the new program's, compared by path: the same set, the
/// same content counts and the same counting flags.
fn expect_same_containers(gpa: std.mem.Allocator, json: []const u8) !void {
    assert(json.len < 1 << 24);
    assert(json.len > 0);
    var program = try ink_json.load(gpa, json);
    defer program.deinit(gpa);
    var story = try Story.initFromJson(gpa, json);
    defer story.deinit();
    try std.testing.expectEqual(story.containers.len, program.containers.len);
    for (story.containers) |old| {
        // Resolve the old path in the new program with ink's rules: the old runtime names some
        // content-nested containers by index where ink uses their name, and both reach the
        // same container.
        const parsed = try ink_path.Path.parse(old.path, 64);
        const target = try ink_path.resolve(&program, .{ .container = Program.root }, parsed);
        if (target.approximate or target.content_index != null) {
            std.debug.print("old path \"{s}\" doesn't resolve in the program\n", .{old.path});
            return error.MissingPath;
        }
        const position = target.container.to_int();
        const info = program.containers.get(position);
        try std.testing.expectEqual(@as(u32, @intCast(old.content.len)), info.instruction_count);
        try std.testing.expectEqual(old.flags.visits_should_be_counted, info.flags.visits_counted);
        try std.testing.expectEqual(
            old.flags.turn_index_should_be_counted,
            info.flags.turns_counted,
        );
        try std.testing.expectEqual(old.flags.count_at_start_only, info.flags.count_start_only);
    }
}

test "the loaded program matches the old runtime's containers on every fixture" {
    // Goal: P3.3; structural parity with the old Story.containers. Method: every
    // inklecate-compiled fixture, loaded by both, compared container by container.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fixtures = try @import("transcripts.zig").collect_fixtures(arena, io);
    var compared: u32 = 0;
    for (fixtures) |id| {
        const path = try std.fmt.allocPrint(arena, "test/fixture/compiled/{s}.ink.json", .{id});
        const json = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 24));
        expect_same_containers(gpa, json) catch |err| {
            std.debug.print("container mismatch in {s}: {t}\n", .{ path, err });
            return err;
        };
        compared += 1;
    }
    try std.testing.expect(compared > 150);
}
