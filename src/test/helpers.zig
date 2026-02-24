const std = @import("std");
const builtin = @import("builtin");

/// Load a fixture file from the test/fixture/compiled/ directory.
/// Caller owns the returned memory (allocated with allocator).
pub fn loadFixture(allocator: std.mem.Allocator, comptime rel_path: []const u8) ![]const u8 {
    const path = "test/fixture/compiled/" ++ rel_path;
    var threaded: std.Io.Threaded = if (builtin.single_threaded)
        .init_single_threaded
    else
        .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024));
}

test "loadFixture returns non-empty slice" {
    const data = try loadFixture(std.testing.allocator, "runtime/misc/hello_world.ink.json");
    defer std.testing.allocator.free(data);
    try std.testing.expect(data.len > 0);
}
