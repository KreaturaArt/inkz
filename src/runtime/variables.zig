const std = @import("std");
const value = @import("value.zig");

pub const RuntimeObject = value.RuntimeObject;

pub const VariablesState = struct {
    globals: std.StringHashMapUnmanaged(RuntimeObject),

    pub fn init() VariablesState {
        return .{ .globals = .{} };
    }

    pub fn deinit(self: *VariablesState, allocator: std.mem.Allocator) void {
        self.globals.deinit(allocator);
    }

    pub fn get(self: *const VariablesState, name: []const u8) ?RuntimeObject {
        return self.globals.get(name);
    }

    pub fn set(self: *VariablesState, allocator: std.mem.Allocator, name: []const u8, val: RuntimeObject) !void {
        try self.globals.put(allocator, name, val);
    }

    pub fn clone(self: *const VariablesState, allocator: std.mem.Allocator) !VariablesState {
        var new_vs = VariablesState.init();
        var it = self.globals.iterator();
        while (it.next()) |entry| {
            try new_vs.globals.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
        }
        return new_vs;
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "VariablesState basic" {
    const alloc = std.testing.allocator;
    var vs = VariablesState.init();
    defer vs.deinit(alloc);

    try vs.set(alloc, "x", .{ .int = 5 });
    try std.testing.expectEqual(@as(i64, 5), vs.get("x").?.int);
    try std.testing.expectEqual(@as(?RuntimeObject, null), vs.get("unknown"));

    try vs.set(alloc, "x", .{ .int = 10 });
    try std.testing.expectEqual(@as(i64, 10), vs.get("x").?.int);
}
