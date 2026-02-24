const std = @import("std");

pub const PathComponent = union(enum) {
    name: []const u8,
    index: u32,
    /// Parent reference "^"
    parent,

    pub fn eql(self: PathComponent, other: PathComponent) bool {
        return switch (self) {
            .name => |n| switch (other) {
                .name => |m| std.mem.eql(u8, n, m),
                else => false,
            },
            .index => |i| switch (other) {
                .index => |j| i == j,
                else => false,
            },
            .parent => switch (other) {
                .parent => true,
                else => false,
            },
        };
    }
};

pub const Path = struct {
    components: []PathComponent,
    is_relative: bool,

    /// Parse an Ink path string.
    /// A path starting with "." is relative; all others are absolute.
    pub fn fromString(allocator: std.mem.Allocator, s: []const u8) !Path {
        if (s.len == 0) {
            return Path{ .components = &.{}, .is_relative = false };
        }

        var is_relative = false;
        var tail = s;
        if (tail[0] == '.') {
            is_relative = true;
            tail = tail[1..];
        }

        var components = std.ArrayList(PathComponent).empty;
        errdefer components.deinit(allocator);

        var iter = std.mem.splitScalar(u8, tail, '.');
        while (iter.next()) |part| {
            if (part.len == 0) continue;
            if (std.mem.eql(u8, part, "^")) {
                try components.append(allocator, .parent);
            } else if (std.fmt.parseInt(u32, part, 10)) |idx| {
                try components.append(allocator, .{ .index = idx });
            } else |_| {
                try components.append(allocator, .{ .name = part });
            }
        }

        return Path{
            .components = try components.toOwnedSlice(allocator),
            .is_relative = is_relative,
        };
    }

    pub fn toString(self: Path, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);

        if (self.is_relative) {
            try buf.append(allocator, '.');
        }

        for (self.components, 0..) |comp, i| {
            if (i > 0) try buf.append(allocator, '.');
            switch (comp) {
                .name => |n| try buf.appendSlice(allocator, n),
                .index => |idx| {
                    var tmp: [20]u8 = undefined;
                    const s = std.fmt.bufPrint(&tmp, "{}", .{idx}) catch unreachable;
                    try buf.appendSlice(allocator, s);
                },
                .parent => try buf.append(allocator, '^'),
            }
        }

        return buf.toOwnedSlice(allocator);
    }

    pub fn deinit(self: *Path, allocator: std.mem.Allocator) void {
        allocator.free(self.components);
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "Path.fromString absolute" {
    const alloc = std.testing.allocator;

    var p1 = try Path.fromString(alloc, "0.g-0");
    defer p1.deinit(alloc);
    try std.testing.expect(!p1.is_relative);
    try std.testing.expectEqual(@as(usize, 2), p1.components.len);
    try std.testing.expectEqual(PathComponent{ .index = 0 }, p1.components[0]);
    try std.testing.expectEqualStrings("g-0", p1.components[1].name);
}

test "Path.fromString relative" {
    const alloc = std.testing.allocator;

    var p = try Path.fromString(alloc, ".^.1");
    defer p.deinit(alloc);
    try std.testing.expect(p.is_relative);
    try std.testing.expectEqual(@as(usize, 2), p.components.len);
    try std.testing.expectEqual(PathComponent.parent, p.components[0]);
    try std.testing.expectEqual(PathComponent{ .index = 1 }, p.components[1]);
}

test "Path.fromString name only" {
    const alloc = std.testing.allocator;

    var p = try Path.fromString(alloc, "f");
    defer p.deinit(alloc);
    try std.testing.expect(!p.is_relative);
    try std.testing.expectEqual(@as(usize, 1), p.components.len);
    try std.testing.expectEqualStrings("f", p.components[0].name);
}

test "Path.fromString long path" {
    const alloc = std.testing.allocator;

    var p = try Path.fromString(alloc, "building.entrance.3.0");
    defer p.deinit(alloc);
    try std.testing.expect(!p.is_relative);
    try std.testing.expectEqual(@as(usize, 4), p.components.len);
}

test "Path round-trip" {
    const alloc = std.testing.allocator;

    const cases = [_][]const u8{ "0.g-0", ".^.1", "f", "building.entrance.3.0" };
    for (cases) |s| {
        var p = try Path.fromString(alloc, s);
        defer p.deinit(alloc);
        const out = try p.toString(alloc);
        defer alloc.free(out);
        try std.testing.expectEqualStrings(s, out);
    }
}
