//! Typed `u32` indices. Each index type is a distinct non-exhaustive enum, so a
//! `ContainerIndex` can't be passed where a `StringId` is expected. `.none` is the largest
//! `u32` and means "no index"; it is never a valid position.

const std = @import("std");
const assert = std.debug.assert;

/// Creates a distinct index type. `name` only makes the type unique and readable in errors.
pub fn Index(comptime name: []const u8) type {
    comptime assert(name.len > 0);
    return enum(u32) {
        none = std.math.maxInt(u32),
        _,

        const Self = @This();
        pub const type_name = name;

        /// Wraps a position. `value` must not be the `.none` bit pattern.
        pub fn from_int(value: u32) Self {
            assert(value != @backingInt(Self.none));
            const index: Self = @fromBackingInt(@intCast(value));
            assert(index != .none);
            return index;
        }

        /// Unwraps a position. Panics on `.none`, which has no position.
        pub fn to_int(index: Self) u32 {
            assert(index != .none);
            const value = @backingInt(index);
            assert(value < std.math.maxInt(u32));
            return value;
        }

        pub fn is_none(index: Self) bool {
            const result = index == .none;
            assert(result == (@backingInt(index) == std.math.maxInt(u32)));
            if (!result) assert(@backingInt(index) < std.math.maxInt(u32));
            return result;
        }

        /// Like `from_int`, but `.none` for `null`.
        pub fn from_optional(value: ?u32) Self {
            const index: Self = if (value) |position| from_int(position) else .none;
            assert((value == null) == (index == .none));
            if (value) |position| assert(@backingInt(index) == position);
            return index;
        }

        /// Like `to_int`, but `null` for `.none`.
        pub fn to_optional(index: Self) ?u32 {
            const value: ?u32 = if (index == .none) null else index.to_int();
            assert((value == null) == (index == .none));
            if (value) |position| assert(position < std.math.maxInt(u32));
            return value;
        }

        comptime {
            assert(@sizeOf(Self) == 4);
            assert(@typeInfo(Self).@"enum".tag_type == u32);
        }
    };
}

pub const ContainerIndex = Index("container");
pub const InstructionIndex = Index("instruction");
pub const StringId = Index("string");
pub const NodeIndex = Index("node");
pub const TokenIndex = Index("token");
pub const GlobalSlot = Index("global");
pub const ListItemIndex = Index("list_item");
pub const ListOriginIndex = Index("list_origin");
pub const ExternalIndex = Index("external");
pub const FlowIndex = Index("flow");
pub const FileIndex = Index("file");

comptime {
    assert(ContainerIndex != StringId);
    assert(NodeIndex != TokenIndex);
}

test "from_int and to_int round-trip, including the extremes" {
    // Positions survive wrapping: round-trip 0, a middle value and the largest
    // valid position (one below `.none`).
    const values = [_]u32{ 0, 1, 12345, std.math.maxInt(u32) - 1 };
    for (values) |value| {
        const index = ContainerIndex.from_int(value);
        try std.testing.expectEqual(value, index.to_int());
        try std.testing.expect(!index.is_none());
    }
}

test "none and optionals" {
    // `.none` and `null` map onto each other in both directions: convert both
    // ways for a present and an absent value.
    try std.testing.expect(StringId.none.is_none());
    try std.testing.expectEqual(StringId.none, StringId.from_optional(null));
    try std.testing.expectEqual(@as(?u32, null), StringId.none.to_optional());
    try std.testing.expectEqual(@as(?u32, 7), StringId.from_optional(7).to_optional());
}

test "index types are distinct and 4 bytes" {
    // Type safety without size cost: compare the types and their sizes.
    try std.testing.expect(ContainerIndex != InstructionIndex);
    try std.testing.expectEqual(4, @sizeOf(FileIndex));
    try std.testing.expectEqualStrings("list_item", ListItemIndex.type_name);
}
