//! List values (plan §4.4, P4.2) and ink's list operations (InkList.cs).
//!
//! A C# InkList is a Dictionary, so its iteration order is insertion order, and that order
//! decides LIST_RANDOM, ties in LIST_MIN and LIST_MAX, and the origin an int is converted
//! through. ink only ever copies a list and then adds to or removes from the copy, so freed
//! dictionary slots are never reused and the order is exactly insertion order with removals
//! taken out. A list value therefore stores its items as an ordered array (plan D15), plus the
//! origins it was declared with, which only matter while it is empty. Lists are short, so
//! membership is a linear scan.
//!
//! The slab is a fixed array of words: a list is `[items_count, origins_count, items...,
//! origins...]`. Reclaiming dead lists is the heap's job (P4.3).

const std = @import("std");
const assert = std.debug.assert;
const index = @import("../core/index.zig");
const Program = @import("../core/program.zig").Program;
const Opcode = @import("../core/instruction.zig").Opcode;
const value_module = @import("value.zig");
const native = @import("native.zig");
const Value = value_module.Value;
const ListReference = value_module.ListReference;
const ListItemIndex = index.ListItemIndex;
const ListOriginIndex = index.ListOriginIndex;

pub const Error = native.Error || error{ListLimit};

pub const View = struct {
    items: []const ListItemIndex,
    /// The declared origins; used only when `items` is empty.
    origins: []const ListOriginIndex,
};

pub const ListSlab = struct {
    words: []u32,
    used: u32 = 0,
    /// The most words in use at once since init (P10.2).
    peak: u32 = 0,

    /// A list is `[forward, items_count, origins_count, items..., origins...]`. `forward` is
    /// `unmarked` except during compaction (heap.zig), when it holds the list's new offset.
    pub const header_words = 3;
    pub const unmarked = std.math.maxInt(u32);

    pub fn init(words: []u32) ListSlab {
        assert(words.len <= std.math.maxInt(u32));
        const slab: ListSlab = .{ .words = words };
        assert(slab.used == 0);
        return slab;
    }

    /// Stores a list and returns its reference; `error.ListLimit` when the slab is full.
    pub fn store(
        slab: *ListSlab,
        items: []const ListItemIndex,
        origins: []const ListOriginIndex,
    ) error{ListLimit}!ListReference {
        assert(slab.used <= slab.words.len);
        const words_count = header_words + items.len + origins.len;
        if (words_count > slab.words.len - slab.used) return error.ListLimit;
        const at = slab.used;
        slab.words[at] = unmarked;
        slab.words[at + 1] = @intCast(items.len);
        slab.words[at + 2] = @intCast(origins.len);
        const items_at = at + header_words;
        for (items, 0..) |item, offset| slab.words[items_at + offset] = @backingInt(item);
        const origins_at = items_at + items.len;
        for (origins, 0..) |origin, offset| slab.words[origins_at + offset] = @backingInt(origin);
        slab.used += @intCast(words_count);
        slab.peak = @max(slab.peak, slab.used);
        assert(slab.used <= slab.words.len);
        return @fromBackingInt(@intCast(at));
    }

    /// Drops every list from `top` on; `top` must be an object boundary.
    pub fn truncate(slab: *ListSlab, top: u32) void {
        assert(top <= slab.used);
        assert(slab.used <= slab.words.len);
        if (std.debug.runtime_safety) @memset(slab.words[top..slab.used], unmarked);
        slab.used = top;
    }

    /// Whether `list` can be a list's start: its header fits, counts fit the used words.
    /// Not proof that it is one; a full walk would be (heap.zig's compaction does that).
    pub fn check_reference(slab: *const ListSlab, list: ListReference) bool {
        assert(slab.used <= slab.words.len);
        const at: u64 = @backingInt(list);
        if (at + header_words > slab.used) return false;
        const index_at: u32 = @intCast(at);
        if (slab.words[index_at] != unmarked) return false;
        const total = header_words + @as(u64, slab.words[index_at + 1]) + slab.words[index_at + 2];
        assert(total >= header_words);
        return at + total <= slab.used;
    }

    /// The words the list at `at` takes, header included.
    pub fn object_words(slab: *const ListSlab, at: u32) u32 {
        assert(at + header_words <= slab.used);
        const count = header_words + slab.words[at + 1] + slab.words[at + 2];
        assert(at + count <= slab.used);
        return count;
    }

    pub fn view(slab: *const ListSlab, list: ListReference) View {
        assert(slab.used <= slab.words.len);
        const at = @backingInt(list);
        const total = slab.object_words(at);
        const items_count = slab.words[at + 1];
        const origins_count = slab.words[at + 2];
        assert(total == header_words + items_count + origins_count);
        const items_words = slab.words[at + header_words ..][0..items_count];
        const origins_words = slab.words[at + header_words + items_count ..][0..origins_count];
        return .{ .items = @ptrCast(items_words), .origins = @ptrCast(origins_words) };
    }
};

/// Builds a list in a bounded scratch buffer before storing it.
const Builder = struct {
    items: [items_max]ListItemIndex = undefined,
    items_count: u32 = 0,
    origins: [origins_max]ListOriginIndex = undefined,
    origins_count: u32 = 0,

    const items_max = 1024;
    const origins_max = 64;

    fn contains(builder: *const Builder, item: ListItemIndex) bool {
        assert(item.to_int() < std.math.maxInt(u32));
        assert(builder.items_count <= items_max);
        const items = builder.items[0..builder.items_count];
        return std.mem.indexOfScalar(ListItemIndex, items, item) != null;
    }

    fn add(builder: *Builder, item: ListItemIndex) error{ListLimit}!void {
        assert(builder.items_count <= items_max);
        assert(!item.is_none());
        if (builder.contains(item)) return;
        if (builder.items_count == items_max) return error.ListLimit;
        builder.items[builder.items_count] = item;
        builder.items_count += 1;
    }

    fn add_origin(builder: *Builder, origin: ListOriginIndex) error{ListLimit}!void {
        assert(builder.origins_count <= origins_max);
        assert(!origin.is_none());
        const known = builder.origins[0..builder.origins_count];
        if (std.mem.indexOfScalar(ListOriginIndex, known, origin) != null) return;
        if (builder.origins_count == origins_max) return error.ListLimit;
        builder.origins[builder.origins_count] = origin;
        builder.origins_count += 1;
    }

    fn finish(builder: *const Builder, slab: *ListSlab) error{ListLimit}!Value {
        assert(builder.origins_count <= origins_max);
        assert(builder.items_count <= items_max);
        const list = try slab.store(
            builder.items[0..builder.items_count],
            builder.origins[0..builder.origins_count],
        );
        return .{ .list = list };
    }
};

/// List operations over one program and slab.
pub const Lists = struct {
    program: *const Program,
    slab: *ListSlab,

    fn item_value(lists: Lists, item: ListItemIndex) i32 {
        assert(!item.is_none());
        assert(item.to_int() < lists.program.list_items.len);
        return lists.program.list_items[item.to_int()].value;
    }

    fn item_origin(lists: Lists, item: ListItemIndex) ListOriginIndex {
        assert(!item.is_none());
        assert(item.to_int() < lists.program.list_items.len);
        return lists.program.list_items[item.to_int()].origin;
    }

    fn contains(items: []const ListItemIndex, item: ListItemIndex) bool {
        assert(items.len < 1 << 20);
        assert(!item.is_none());
        return std.mem.indexOfScalar(ListItemIndex, items, item) != null;
    }

    /// ink's `originNames`: the items' origins in order when there are items, else the
    /// declared ones. Copies of a list keep these as their declared origins.
    fn origin_names(lists: Lists, list: View, builder: *Builder) error{ListLimit}!void {
        assert(lists.slab.used <= lists.slab.words.len);
        assert(builder.origins_count == 0);
        if (list.items.len == 0) {
            for (list.origins) |origin| try builder.add_origin(origin);
            return;
        }
        for (list.items) |item| try builder.add_origin(lists.item_origin(item));
    }

    /// The first item with the highest value, in iteration order (ink's `maxItem`).
    pub fn max_item(lists: Lists, list: View) ?ListItemIndex {
        assert(lists.slab.used <= lists.slab.words.len);
        var best: ?ListItemIndex = null;
        for (list.items) |item| {
            if (best == null or lists.item_value(item) > lists.item_value(best.?)) best = item;
        }
        assert((best == null) == (list.items.len == 0));
        return best;
    }

    /// The first item with the lowest value, in iteration order (ink's `minItem`).
    pub fn min_item(lists: Lists, list: View) ?ListItemIndex {
        assert(lists.slab.used <= lists.slab.words.len);
        var best: ?ListItemIndex = null;
        for (list.items) |item| {
            if (best == null or lists.item_value(item) < lists.item_value(best.?)) best = item;
        }
        assert((best == null) == (list.items.len == 0));
        return best;
    }

    /// ink's ListWithSubRange (LIST_RANGE): the items with values in `[minimum, maximum]`,
    /// in iteration order. A bound is an int, or a non-empty list's lowest (or highest)
    /// value; anything else leaves the bound open.
    pub fn sub_range(
        lists: Lists,
        list: ListReference,
        minimum: Value,
        maximum: Value,
    ) Error!Value {
        assert(lists.slab.used <= lists.slab.words.len);
        const view = lists.slab.view(list);
        var builder: Builder = .{};
        if (view.items.len == 0) return builder.finish(lists.slab);
        var low: i32 = 0;
        var high: i32 = std.math.maxInt(i32);
        switch (minimum) {
            .integer => |number| low = number,
            .list => |bound| if (lists.min_item(lists.slab.view(bound))) |item| {
                low = lists.item_value(item);
            },
            else => {},
        }
        switch (maximum) {
            .integer => |number| high = number,
            .list => |bound| if (lists.max_item(lists.slab.view(bound))) |item| {
                high = lists.item_value(item);
            },
            else => {},
        }
        try lists.origin_names(view, &builder);
        for (view.items) |item| {
            const value = lists.item_value(item);
            if (value >= low and value <= high) try builder.add(item);
        }
        assert(builder.items_count <= view.items.len);
        return builder.finish(lists.slab);
    }

    /// The list item of origin `origin_name` with value `value` as a one-item list, an
    /// empty list if the origin has no such item, or null if there is no such origin
    /// (ink's ListFromInt).
    pub fn from_int(lists: Lists, origin_name: []const u8, value: i32) Error!?Value {
        assert(lists.slab.used <= lists.slab.words.len);
        const strings = &lists.program.strings;
        for (lists.program.list_origins, 0..) |origin, position| {
            if (!std.mem.eql(u8, strings.get(origin.name), origin_name)) continue;
            var builder: Builder = .{};
            if (lists.item_with_value(.from_int(@intCast(position)), value)) |item| {
                try builder.add(item);
                try builder.add_origin(.from_int(@intCast(position)));
            }
            return try builder.finish(lists.slab);
        }
        assert(lists.program.list_origins.len < std.math.maxInt(u32));
        return null;
    }

    /// The item at `position` in iteration (insertion) order, as a one-item list.
    pub fn item_list(lists: Lists, list: ListReference, position: u32) Error!Value {
        assert(lists.slab.used <= lists.slab.words.len);
        const view = lists.slab.view(list);
        assert(position < view.items.len);
        const item = view.items[position];
        var builder: Builder = .{};
        try builder.add(item);
        try builder.add_origin(lists.item_origin(item));
        return builder.finish(lists.slab);
    }

    /// An empty list declared with `old`'s origins (ink's RetainListOriginsForAssignment).
    pub fn empty_with_origins_of(lists: Lists, old: ListReference) Error!Value {
        assert(lists.slab.used <= lists.slab.words.len);
        var builder: Builder = .{};
        try lists.origin_names(lists.slab.view(old), &builder);
        assert(builder.items_count == 0);
        return builder.finish(lists.slab);
    }

    pub fn count(lists: Lists, list: ListReference) u32 {
        assert(lists.slab.used <= lists.slab.words.len);
        const items_count: u32 = @intCast(lists.slab.view(list).items.len);
        assert(items_count <= lists.program.list_items.len);
        return items_count;
    }

    /// `list + int` and `list - int`: each item moves to the item of its origin with the new
    /// value, if there is one.
    fn increment(lists: Lists, list: View, opcode: Opcode, amount: i32) Error!Value {
        assert(lists.slab.used <= lists.slab.words.len);
        assert(opcode == .add or opcode == .subtract);
        var builder: Builder = .{};
        for (list.items) |item| {
            const value = lists.item_value(item);
            const target = if (opcode == .add) value +% amount else value -% amount;
            if (lists.item_with_value(lists.item_origin(item), target)) |moved| try builder.add(
                moved,
            );
        }
        return builder.finish(lists.slab);
    }

    pub fn item_with_value(lists: Lists, origin: ListOriginIndex, value: i32) ?ListItemIndex {
        assert(origin.to_int() < lists.program.list_origins.len);
        const info = lists.program.list_origins[origin.to_int()];
        const first = info.items_first.to_int();
        for (lists.program.list_items[first..][0..info.items_count], first..) |item, position| {
            if (item.value == value) return .from_int(@intCast(position));
        }
        assert(info.items_count <= lists.program.list_items.len);
        return null;
    }

    /// Coerces an int to a one-item list through the origin of `list`'s highest item, as
    /// ink's CoerceValuesToSingleType does.
    fn int_as_list(lists: Lists, list: View, number: i32) Error!View {
        assert(lists.slab.used <= lists.slab.words.len);
        var origins: Builder = .{};
        try lists.origin_names(list, &origins);
        const max = lists.max_item(list);
        const origin = if (max) |item| lists.item_origin(item) else if (origins.origins_count > 0)
            origins.origins[0]
        else
            return error.IncompatibleTypes;
        const item = lists.item_with_value(origin, number) orelse return error.IncompatibleTypes;
        const reference = try lists.slab.store(&.{item}, &.{});
        assert(!item.is_none());
        return lists.slab.view(reference);
    }

    pub fn binary(lists: Lists, opcode: Opcode, a: Value, b: Value) Error!Value {
        assert(lists.slab.used <= lists.slab.words.len);
        assert(a == .list or b == .list);
        if (a == .list and b == .integer and (opcode == .add or opcode == .subtract)) {
            return lists.increment(lists.slab.view(a.list), opcode, b.integer);
        }
        const left = try lists.as_list(a, b);
        const right = try lists.as_list(b, a);
        return lists.list_binary(opcode, left, right);
    }

    fn as_list(lists: Lists, value: Value, other: Value) Error!View {
        assert(lists.slab.used <= lists.slab.words.len);
        if (value == .list) return lists.slab.view(value.list);
        if (value == .integer and other == .list) {
            return lists.int_as_list(lists.slab.view(other.list), value.integer);
        }
        assert(value != .list);
        return error.IncompatibleTypes;
    }

    fn list_binary(lists: Lists, opcode: Opcode, a: View, b: View) Error!Value {
        assert(lists.slab.used <= lists.slab.words.len);
        assert(a.items.len <= lists.program.list_items.len);
        return switch (opcode) {
            .add => lists.@"union"(a, b),
            .subtract => lists.without(a, b),
            .intersect => lists.intersect(a, b),
            .has => .{ .bool = lists.contains_all(a, b) },
            .hasnt => .{ .bool = !lists.contains_all(a, b) },
            .equal => .{ .bool = lists.equal(a, b) },
            .not_equal => .{ .bool = !lists.equal(a, b) },
            .greater, .less, .greater_or_equal, .less_or_equal => compared: {
                break :compared .{ .bool = lists.compare(opcode, a, b) };
            },
            .@"and" => .{ .bool = a.items.len > 0 and b.items.len > 0 },
            .@"or" => .{ .bool = a.items.len > 0 or b.items.len > 0 },
            else => error.UnsupportedOperation,
        };
    }

    fn @"union"(lists: Lists, a: View, b: View) Error!Value {
        var builder: Builder = .{};
        try lists.origin_names(a, &builder);
        for (a.items) |item| try builder.add(item);
        for (b.items) |item| try builder.add(item);
        assert(builder.items_count >= a.items.len);
        return builder.finish(lists.slab);
    }

    fn without(lists: Lists, a: View, b: View) Error!Value {
        assert(lists.slab.used <= lists.slab.words.len);
        var builder: Builder = .{};
        try lists.origin_names(a, &builder);
        for (a.items) |item| {
            if (!contains(b.items, item)) try builder.add(item);
        }
        assert(builder.items_count <= a.items.len);
        return builder.finish(lists.slab);
    }

    fn intersect(lists: Lists, a: View, b: View) Error!Value {
        assert(lists.slab.used <= lists.slab.words.len);
        // A new list in ink, so it has no declared origins.
        var builder: Builder = .{};
        for (a.items) |item| {
            if (contains(b.items, item)) try builder.add(item);
        }
        assert(builder.items_count <= @min(a.items.len, b.items.len));
        return builder.finish(lists.slab);
    }

    /// ink's `Contains`: false if either list is empty.
    fn contains_all(lists: Lists, a: View, b: View) bool {
        assert(lists.slab.used <= lists.slab.words.len);
        assert(a.items.len <= lists.program.list_items.len);
        if (a.items.len == 0 or b.items.len == 0) return false;
        for (b.items) |item| {
            if (!contains(a.items, item)) return false;
        }
        return true;
    }

    fn equal(lists: Lists, a: View, b: View) bool {
        assert(lists.slab.used <= lists.slab.words.len);
        assert(b.items.len <= lists.program.list_items.len);
        if (a.items.len != b.items.len) return false;
        for (a.items) |item| {
            if (!contains(b.items, item)) return false;
        }
        return true;
    }

    fn compare(lists: Lists, opcode: Opcode, a: View, b: View) bool {
        assert(lists.slab.used <= lists.slab.words.len);
        const a_min = if (lists.min_item(a)) |item| lists.item_value(item) else 0;
        const a_max = if (lists.max_item(a)) |item| lists.item_value(item) else 0;
        const b_min = if (lists.min_item(b)) |item| lists.item_value(item) else 0;
        const b_max = if (lists.max_item(b)) |item| lists.item_value(item) else 0;
        const result = switch (opcode) {
            .greater => a.items.len > 0 and (b.items.len == 0 or a_min > b_max),
            .greater_or_equal => a.items.len > 0 and
                (b.items.len == 0 or (a_min >= b_min and a_max >= b_max)),
            .less => b.items.len > 0 and (a.items.len == 0 or a_max < b_min),
            .less_or_equal => b.items.len > 0 and
                (a.items.len == 0 or (a_max <= b_max and a_min <= b_min)),
            else => unreachable,
        };
        assert(opcode != .greater or a.items.len > 0 or !result);
        return result;
    }

    pub fn unary(lists: Lists, opcode: Opcode, a: Value) Error!Value {
        assert(lists.slab.used <= lists.slab.words.len);
        assert(a == .list);
        const list = lists.slab.view(a.list);
        return switch (opcode) {
            // ink returns an int here, not a bool.
            .not => .{ .integer = @intFromBool(list.items.len == 0) },
            .list_count => .{ .integer = @intCast(list.items.len) },
            .list_value => valued: {
                const max = lists.max_item(list) orelse break :valued .{ .integer = 0 };
                break :valued .{ .integer = lists.item_value(max) };
            },
            .list_min => lists.single(lists.min_item(list)),
            .list_max => lists.single(lists.max_item(list)),
            .list_all => lists.all(list, false),
            .list_invert => lists.all(list, true),
            else => error.UnsupportedOperation,
        };
    }

    fn single(lists: Lists, item: ?ListItemIndex) Error!Value {
        assert(lists.slab.used <= lists.slab.words.len);
        const items: []const ListItemIndex = if (item) |found| &.{found} else &.{};
        const reference = try lists.slab.store(items, &.{});
        assert(lists.slab.view(reference).items.len == items.len);
        assert(@backingInt(reference) < lists.slab.used);
        return .{ .list = reference };
    }

    /// Every item of the list's origins (LIST_ALL), or those it lacks (LIST_INVERT), in
    /// definition order.
    fn all(lists: Lists, list: View, invert: bool) Error!Value {
        assert(lists.slab.used <= lists.slab.words.len);
        var origins: Builder = .{};
        try lists.origin_names(list, &origins);
        var builder: Builder = .{};
        for (origins.origins[0..origins.origins_count]) |origin| {
            const info = lists.program.list_origins[origin.to_int()];
            const first = info.items_first.to_int();
            for (first..first + info.items_count) |position| {
                const item: ListItemIndex = .from_int(@intCast(position));
                if (invert and contains(list.items, item)) continue;
                try builder.add(item);
            }
        }
        assert(builder.items_count <= lists.program.list_items.len);
        return builder.finish(lists.slab);
    }

    /// The list's text: item names ordered by value, then by origin name (InkList.ToString).
    pub fn write(lists: Lists, list: ListReference, writer: *std.Io.Writer) !void {
        assert(lists.slab.used <= lists.slab.words.len);
        const items = lists.slab.view(list).items;
        var ordered: [Builder.items_max]ListItemIndex = undefined;
        @memcpy(ordered[0..items.len], items);
        std.mem.sort(ListItemIndex, ordered[0..items.len], lists, display_less_than);
        for (ordered[0..items.len], 0..) |item, position| {
            if (position > 0) try writer.writeAll(", ");
            const name = lists.program.list_items[item.to_int()].name;
            try writer.writeAll(lists.program.strings.get(name));
        }
        assert(items.len <= Builder.items_max);
    }

    fn display_less_than(lists: Lists, a: ListItemIndex, b: ListItemIndex) bool {
        assert(!a.is_none());
        assert(!b.is_none());
        const value_a = lists.item_value(a);
        const value_b = lists.item_value(b);
        if (value_a != value_b) return value_a < value_b;
        const strings = &lists.program.strings;
        const origins = lists.program.list_origins;
        const origin_a = strings.get(origins[lists.item_origin(a).to_int()].name);
        const origin_b = strings.get(origins[lists.item_origin(b).to_int()].name);
        return std.mem.order(u8, origin_a, origin_b) == .lt;
    }
};

const ProgramBuilder = @import("../core/program_builder.zig").ProgramBuilder;

/// colours: red 1, green 2, blue 3; sizes: small 1, large 3.
fn test_program(gpa: std.mem.Allocator) !Program {
    assert(@sizeOf(ListItemIndex) == 4);
    var builder = try ProgramBuilder.init(gpa);
    defer builder.deinit();
    _ = try builder.begin_container(.{});
    try builder.add(.done, {});
    try builder.end_container();
    _ = try builder.list_origin("colours", &.{
        .{ .name = "red", .value = 1 },
        .{ .name = "green", .value = 2 },
        .{ .name = "blue", .value = 3 },
    });
    _ = try builder.list_origin(
        "sizes",
        &.{ .{ .name = "small", .value = 1 }, .{ .name = "large", .value = 3 } },
    );
    const program = try builder.finish();
    assert(program.list_items.len == 5);
    return program;
}

const red: ListItemIndex = .from_int(0);
const green: ListItemIndex = .from_int(1);
const blue: ListItemIndex = .from_int(2);
const small: ListItemIndex = .from_int(3);
const large: ListItemIndex = .from_int(4);
const colours: ListOriginIndex = .from_int(0);

fn expect_items(lists: Lists, value: Value, expected: []const ListItemIndex) !void {
    assert(value == .list);
    assert(expected.len < 64);
    try std.testing.expectEqualSlices(ListItemIndex, expected, lists.slab.view(value.list).items);
}

test "set operations keep ink's iteration order" {
    // Goal: union, without and intersection follow C# Dictionary order. Method: lists built
    // in an order different from value order.
    var program = try test_program(std.testing.allocator);
    defer program.deinit(std.testing.allocator);
    var words: [256]u32 = undefined;
    var slab = ListSlab.init(&words);
    const lists: Lists = .{ .program = &program, .slab = &slab };
    const blue_red: Value = .{ .list = try slab.store(&.{ blue, red }, &.{}) };
    const green_blue: Value = .{ .list = try slab.store(&.{ green, blue }, &.{}) };
    try expect_items(lists, try lists.binary(.add, blue_red, green_blue), &.{ blue, red, green });
    try expect_items(lists, try lists.binary(.subtract, blue_red, green_blue), &.{red});
    try expect_items(lists, try lists.binary(.intersect, green_blue, blue_red), &.{blue});
    try std.testing.expectEqual(
        Value{ .bool = true },
        try lists.binary(.has, blue_red, .{ .list = try slab.store(&.{red}, &.{}) }),
    );
    const empty: Value = .{ .list = try slab.store(&.{}, &.{colours}) };
    try std.testing.expectEqual(Value{ .bool = false }, try lists.binary(.has, blue_red, empty));
}

test "comparisons, min, max and value" {
    // Goal: ink's GreaterThan etc. use min and max values; ties keep the first item.
    var program = try test_program(std.testing.allocator);
    defer program.deinit(std.testing.allocator);
    var words: [256]u32 = undefined;
    var slab = ListSlab.init(&words);
    const lists: Lists = .{ .program = &program, .slab = &slab };
    const low: Value = .{ .list = try slab.store(&.{ red, green }, &.{}) };
    const high: Value = .{ .list = try slab.store(&.{blue}, &.{}) };
    try std.testing.expectEqual(Value{ .bool = true }, try lists.binary(.less, low, high));
    try std.testing.expectEqual(Value{ .bool = false }, try lists.binary(.greater, low, high));
    try std.testing.expectEqual(Value{ .integer = 2 }, try lists.unary(.list_value, low));
    // large (sizes, 3) comes before blue (colours, 3): the first maximum wins.
    const tied: Value = .{ .list = try slab.store(&.{ large, blue }, &.{}) };
    try expect_items(lists, try lists.unary(.list_max, tied), &.{large});
    try std.testing.expectEqual(Value{ .integer = 2 }, try lists.unary(.list_count, tied));
}

test "all, invert, increment and int coercion" {
    // Goal: origin-based operations, including an empty list that keeps its declared origin.
    var program = try test_program(std.testing.allocator);
    defer program.deinit(std.testing.allocator);
    var words: [256]u32 = undefined;
    var slab = ListSlab.init(&words);
    const lists: Lists = .{ .program = &program, .slab = &slab };
    const just_green: Value = .{ .list = try slab.store(&.{green}, &.{}) };
    try expect_items(lists, try lists.unary(.list_invert, just_green), &.{ red, blue });
    const empty: Value = .{ .list = try slab.store(&.{}, &.{colours}) };
    try expect_items(lists, try lists.unary(.list_all, empty), &.{ red, green, blue });
    try expect_items(lists, try lists.binary(.add, just_green, .{ .integer = 1 }), &.{blue});
    try expect_items(lists, try lists.binary(.add, just_green, .{ .integer = 5 }), &.{});
    try std.testing.expectEqual(Value{ .bool = true }, try lists.binary(.equal, just_green, .{
        .integer = 2,
    }));
    try std.testing.expectError(error.IncompatibleTypes, lists.binary(.equal, just_green, .{
        .integer = 9,
    }));
    try std.testing.expectEqual(Value{ .integer = 1 }, try lists.unary(.not, empty));
}

test "a list prints ordered by value, then origin name" {
    // Goal: InkList.ToString. Method: mixed origins with a value tie.
    var program = try test_program(std.testing.allocator);
    defer program.deinit(std.testing.allocator);
    var words: [256]u32 = undefined;
    var slab = ListSlab.init(&words);
    const lists: Lists = .{ .program = &program, .slab = &slab };
    const mixed = try slab.store(&.{ large, red, blue, small }, &.{});
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try lists.write(mixed, &writer);
    try std.testing.expectEqualStrings("red, small, blue, large", writer.buffered());
}

test "a full slab returns ListLimit" {
    // Goal: the slab never grows. Method: fill a tiny one.
    var words: [6]u32 = undefined;
    var slab = ListSlab.init(&words);
    _ = try slab.store(&.{ red, green }, &.{colours});
    try std.testing.expectError(error.ListLimit, slab.store(&.{red}, &.{}));
}
