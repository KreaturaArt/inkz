const std = @import("std");

/// A runtime Ink list value.
/// Keys are "origin_name.item_name" strings; values are integer values.
/// Using a pointer-stable heap allocation so RuntimeObject.list: *InkList stays copyable.
pub const InkList = struct {
    /// "origin.item" → integer value
    items: std.StringHashMapUnmanaged(i32) = .{},
    /// Origin list names (e.g. ["Colour"]). Used for LIST_ALL and LIST_INVERT.
    origins: []const []const u8 = &.{},

    /// Return a heap-allocated comma-separated display string.
    /// Items are sorted by origin name first, then by value within the origin
    /// (matching the C# Ink runtime's `orderedItems` behaviour).
    /// Caller owns the returned slice. Example: "a, c".
    pub fn toDisplayString(self: *const InkList, allocator: std.mem.Allocator) ![]u8 {
        const Entry = struct { origin: []const u8, name: []const u8, val: i32 };
        var buf: [256]Entry = undefined;
        var count: usize = 0;
        var it = self.items.iterator();
        while (it.next()) |e| {
            if (count >= buf.len) break;
            const full = e.key_ptr.*;
            const dot = std.mem.indexOfScalar(u8, full, '.') orelse full.len;
            const origin = full[0..dot];
            const name = if (dot < full.len) full[dot + 1 ..] else full;
            buf[count] = .{ .origin = origin, .name = name, .val = e.value_ptr.* };
            count += 1;
        }
        const entries = buf[0..count];
        std.sort.block(Entry, entries, {}, struct {
            pub fn lessThan(_: void, a: Entry, b: Entry) bool {
                const cmp = std.mem.order(u8, a.origin, b.origin);
                if (cmp != .eq) return cmp == .lt;
                return a.val < b.val;
            }
        }.lessThan);
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(allocator);
        for (entries, 0..) |e, i| {
            if (i > 0) try result.appendSlice(allocator, ", ");
            try result.appendSlice(allocator, e.name);
        }
        return result.toOwnedSlice(allocator);
    }

    /// Return the maximum integer value in this list, or null if empty.
    pub fn maxValue(self: *const InkList) ?i32 {
        var max: ?i32 = null;
        var it = self.items.iterator();
        while (it.next()) |e| {
            const v = e.value_ptr.*;
            if (max == null or v > max.?) max = v;
        }
        return max;
    }
};

/// A single list origin (e.g. "Colour" with items red=1, green=2, blue=3).
pub const ListDefinition = struct {
    name: []const u8,
    /// item_name → integer value
    items: std.StringHashMapUnmanaged(i32) = .{},

    /// Return the integer value for a named item, or null if not found.
    pub fn valueForItem(self: *const ListDefinition, item_name: []const u8) ?i32 {
        return self.items.get(item_name);
    }

    /// Return the item name for a given integer value, or null if not found.
    pub fn itemForValue(self: *const ListDefinition, val: i32) ?[]const u8 {
        var it = self.items.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == val) return entry.key_ptr.*;
        }
        return null;
    }
};

/// All list origin definitions from the `listDefs` JSON section.
pub const ListDefinitionsOrigin = struct {
    definitions: std.StringHashMapUnmanaged(ListDefinition) = .{},

    pub fn get(self: *const ListDefinitionsOrigin, name: []const u8) ?*const ListDefinition {
        return self.definitions.getPtr(name);
    }

    /// Parse listDefs from a std.json.Value (must be a .object).
    pub fn parse(arena: std.mem.Allocator, json_val: std.json.Value) !ListDefinitionsOrigin {
        var origin = ListDefinitionsOrigin{};
        if (json_val != .object) return origin;
        var it = json_val.object.iterator();
        while (it.next()) |list_entry| {
            const list_name = list_entry.key_ptr.*;
            const list_val = list_entry.value_ptr.*;
            if (list_val != .object) continue;
            var def = ListDefinition{ .name = list_name };
            var item_it = list_val.object.iterator();
            while (item_it.next()) |item_entry| {
                const item_name = item_entry.key_ptr.*;
                const item_val: i32 = switch (item_entry.value_ptr.*) {
                    .integer => |n| @intCast(n),
                    .float => |f| @intFromFloat(f),
                    else => continue,
                };
                try def.items.put(arena, item_name, item_val);
            }
            try origin.definitions.put(arena, list_name, def);
        }
        return origin;
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "ListDefinition valueForItem and itemForValue" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var def = ListDefinition{ .name = "list" };
    try def.items.put(alloc, "a", 1);
    try def.items.put(alloc, "b", 2);
    try def.items.put(alloc, "c", 3);

    try std.testing.expectEqual(@as(?i32, 3), def.valueForItem("c"));
    try std.testing.expectEqual(@as(?i32, null), def.valueForItem("z"));
    try std.testing.expectEqualStrings("c", def.itemForValue(3).?);
    try std.testing.expectEqual(@as(?[]const u8, null), def.itemForValue(99));
}

test "ListDefinitionsOrigin.parse from list_basic_operations" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const json_text = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "test/fixture/compiled/runtime/lists/list_basic_operations.ink.json",
        gpa,
        .limited(1024 * 1024),
    );
    defer gpa.free(json_text);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, json_text, .{});
    const list_defs_val = parsed.object.get("listDefs") orelse std.json.Value{ .null = {} };

    const origin = try ListDefinitionsOrigin.parse(alloc, list_defs_val);
    const def = origin.get("list") orelse return error.ListNotFound;
    try std.testing.expectEqual(@as(usize, 5), def.items.count());
    try std.testing.expectEqual(@as(?i32, 1), def.valueForItem("a"));
    try std.testing.expectEqual(@as(?i32, 5), def.valueForItem("e"));
    try std.testing.expectEqualStrings("c", def.itemForValue(3).?);
}

test "ListDefinitionsOrigin.parse empty listDefs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const empty = std.json.Value{ .object = std.json.ObjectMap.init(alloc) };
    const origin = try ListDefinitionsOrigin.parse(alloc, empty);
    try std.testing.expectEqual(@as(usize, 0), origin.definitions.count());
}

test "InkList toDisplayString: sorted by value, item-name only" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var ink_list = InkList{};
    try ink_list.items.put(arena.allocator(), "list.a", 1);
    try ink_list.items.put(arena.allocator(), "list.c", 3);

    const s = try ink_list.toDisplayString(alloc);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("a, c", s);
}

test "InkList toDisplayString: empty list produces empty string" {
    const alloc = std.testing.allocator;
    const ink_list = InkList{};
    const s = try ink_list.toDisplayString(alloc);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("", s);
}
