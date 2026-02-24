const std = @import("std");

pub const Choice = struct {
    text: []const u8,
    source_path: []const u8,
    /// Path string to the choice target
    target_path: []const u8,
    tags: []const []const u8,
    index: u32,
    original_thread_index: u32,
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "Choice struct" {
    const c = Choice{
        .text = "Go left",
        .source_path = "knot.0",
        .target_path = "knot.1",
        .tags = &.{},
        .index = 0,
        .original_thread_index = 0,
    };
    try std.testing.expectEqualStrings("Go left", c.text);
    try std.testing.expectEqual(@as(u32, 0), c.index);
}
