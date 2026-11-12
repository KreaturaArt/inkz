//! The new loader against the old one (plan P3.1): peak memory while loading the full stories.

const std = @import("std");
const assert = std.debug.assert;
const ink_json = @import("../core/ink_json.zig");
const CountingAllocator = @import("../core/counting_allocator.zig").CountingAllocator;
const Story = @import("../runtime/story.zig").Story;

const PeakBytes = struct { new: u64, old: u64 };

fn measure(path: []const u8) !PeakBytes {
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
