const std = @import("std");
const value = @import("value.zig");

pub const Container = value.Container;
pub const RuntimeObject = value.RuntimeObject;
pub const null_container_idx = value.null_container_idx;

pub const Pointer = struct {
    /// Index into Story.containers; null_container_idx means null pointer.
    container_idx: u32,
    index: i32,

    pub const null_value = Pointer{ .container_idx = null_container_idx, .index = -1 };

    pub fn isNull(self: Pointer) bool {
        return self.container_idx == null_container_idx;
    }

    /// Returns the RuntimeObject at this pointer, or null if out of range.
    pub fn resolve(self: Pointer, containers: []const Container) ?RuntimeObject {
        if (self.isNull()) return null;
        const c = &containers[self.container_idx];
        if (self.index < 0 or self.index >= @as(i32, @intCast(c.content.len))) return null;
        return c.content[@intCast(self.index)];
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "Pointer.null_value" {
    try std.testing.expect(Pointer.null_value.isNull());
    try std.testing.expectEqual(@as(?RuntimeObject, null), Pointer.null_value.resolve(&.{}));
}

test "Pointer resolve" {
    var content = [_]RuntimeObject{
        .{ .int = 10 },
        .{ .string = "hello" },
    };
    const containers = [_]Container{
        Container{ .content = &content },
    };

    const p = Pointer{ .container_idx = 0, .index = 0 };
    try std.testing.expect(!p.isNull());
    const resolved = p.resolve(&containers).?;
    try std.testing.expectEqual(@as(i64, 10), resolved.int);
}

test "Pointer resolve out of bounds" {
    var content = [_]RuntimeObject{.{ .int = 1 }};
    const containers = [_]Container{
        Container{ .content = &content },
    };

    const p = Pointer{ .container_idx = 0, .index = 5 };
    try std.testing.expectEqual(@as(?RuntimeObject, null), p.resolve(&containers));
}
