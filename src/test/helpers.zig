const std = @import("std");
const Story = @import("../runtime/story.zig").Story;

/// Load a fixture file from the test/fixture/compiled/ directory.
/// Caller owns the returned memory (allocated with allocator).
pub fn loadFixture(allocator: std.mem.Allocator, comptime rel_path: []const u8) ![]const u8 {
    const path = "test/fixture/compiled/" ++ rel_path;
    const io = std.testing.io;
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024));
}

// ── Tests ─────────────────────────────────────────────────────────────────────
// The runStory tests moved to src/testing/old_engine.zig (engine-neutral layer, P0.11).

test "loadFixture returns non-empty slice" {
    const data = try loadFixture(std.testing.allocator, "runtime/misc/hello_world.ink.json");
    defer std.testing.allocator.free(data);
    try std.testing.expect(data.len > 0);
}

test "zero allocation in cont: old runtime (skipped, recorded)" {
    // Goal: P0.5 records the zero-allocation gate against the old runtime. Method: count
    // allocator growth across cont() calls on crime_scene. The old runtime returns an owned
    // string from cont() and grows arenas, so this is expected to allocate; the test reports
    // the count and skips. The real gate is P5.11, on the new runtime, and must not skip.
    const CountingAllocator = @import("../core/counting_allocator.zig").CountingAllocator;
    var counting = CountingAllocator.init(std.testing.allocator);
    const gpa = counting.allocator();
    const json = try loadFixture(gpa, "crime_scene.ink.json");
    defer gpa.free(json);
    var story = try Story.initFromJson(gpa, json);
    defer story.deinit();
    const before = counting.growths();
    var calls: u32 = 0;
    while (story.canContinue() and calls < 8) : (calls += 1) {
        const out = try story.cont();
        gpa.free(out);
    }
    const growths = counting.growths() - before;
    if (growths > 0) {
        std.debug.print(
            "skipped: old runtime allocates {d} times in {d} cont() calls (gate is P5.11)\n",
            .{ growths, calls },
        );
        return error.SkipZigTest;
    }
}
