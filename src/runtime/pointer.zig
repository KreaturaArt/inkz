const std = @import("std");
const value = @import("value.zig");

pub const Container = value.Container;
pub const RuntimeObject = value.RuntimeObject;

pub const Pointer = struct {
    container: ?*Container,
    index: i32,

    pub const null_value = Pointer{ .container = null, .index = -1 };

    pub fn isNull(self: Pointer) bool {
        return self.container == null;
    }

    /// Returns the RuntimeObject at this pointer, or null if out of range.
    pub fn resolve(self: Pointer) ?*const RuntimeObject {
        const c = self.container orelse return null;
        if (self.index < 0 or self.index >= @as(i32, @intCast(c.content.len))) return null;
        return &c.content[@intCast(self.index)];
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "Pointer.null_value" {
    try std.testing.expect(Pointer.null_value.isNull());
    try std.testing.expectEqual(@as(?*const RuntimeObject, null), Pointer.null_value.resolve());
}

test "Pointer resolve" {
    var content = [_]RuntimeObject{
        .{ .int = 10 },
        .{ .string = "hello" },
    };
    var c = Container{ .content = &content };

    const p = Pointer{ .container = &c, .index = 0 };
    try std.testing.expect(!p.isNull());
    try std.testing.expectEqual(@as(i64, 10), p.resolve().?.int);
}

test "Pointer resolve out of bounds" {
    var content = [_]RuntimeObject{.{ .int = 1 }};
    var c = Container{ .content = &content };

    const p = Pointer{ .container = &c, .index = 5 };
    try std.testing.expectEqual(@as(?*const RuntimeObject, null), p.resolve());
}
