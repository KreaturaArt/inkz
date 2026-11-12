//! The `extra` side table (plan T9): structs too wide for an instruction operand are stored
//! as consecutive `u32` words, and the instruction keeps their index.
//!
//! A struct's fields must each fit one word: `u32`, `i32`, `f32`, `bool`, an enum whose tag
//! fits 32 bits (index newtypes included), or a `packed struct(u32)`. A variable-length tail
//! follows with `add_slice`; `get` returns where the struct ends so the reader finds it.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub const ExtraBuilder = struct {
    words: std.ArrayList(u32) = .empty,

    pub fn deinit(builder: *ExtraBuilder, gpa: Allocator) void {
        assert(builder.words.items.len <= std.math.maxInt(u32));
        builder.words.deinit(gpa);
        builder.* = undefined;
        assert(@sizeOf(ExtraBuilder) > 0);
    }

    pub fn count(builder: *const ExtraBuilder) u32 {
        const words_count: u32 = @intCast(builder.words.items.len);
        assert(words_count == builder.words.items.len);
        assert(words_count <= std.math.maxInt(u32));
        return words_count;
    }

    /// Appends `value`'s fields and returns the index of the first word.
    pub fn add(builder: *ExtraBuilder, gpa: Allocator, value: anytype) !u32 {
        const T = @TypeOf(value);
        const words_count = comptime fields_count(T);
        const index = try builder.reserve(gpa, T);
        builder.set(index, value);
        assert(builder.count() == index + words_count);
        assert(std.meta.eql(get(T, builder.words.items, index).data, value));
        return index;
    }

    /// Appends a variable-length tail of words and returns the index of the first one.
    pub fn add_slice(builder: *ExtraBuilder, gpa: Allocator, words: []const u32) !u32 {
        const index = builder.count();
        if (words.len > std.math.maxInt(u32) - index) return error.ExtraFull;
        try builder.words.appendSlice(gpa, words);
        assert(builder.count() == index + words.len);
        assert(std.mem.eql(u32, builder.words.items[index..], words));
        return index;
    }

    /// Reserves room for one `T`, to be filled later with `set` (for forward references).
    pub fn reserve(builder: *ExtraBuilder, gpa: Allocator, comptime T: type) !u32 {
        const words_count = comptime fields_count(T);
        const index = builder.count();
        if (words_count > std.math.maxInt(u32) - index) return error.ExtraFull;
        try builder.words.appendNTimes(gpa, 0, words_count);
        assert(builder.count() == index + words_count);
        assert(words_count > 0);
        return index;
    }

    /// Reserves `count` raw words, zeroed, to be filled later; returns the index of the first.
    pub fn reserve_words(builder: *ExtraBuilder, gpa: Allocator, count_words: u32) !u32 {
        const index = builder.count();
        if (count_words > std.math.maxInt(u32) - index) return error.ExtraFull;
        try builder.words.appendNTimes(gpa, 0, count_words);
        assert(builder.count() == index + count_words);
        return index;
    }

    /// Overwrites the `T` stored at `index`.
    pub fn set(builder: *ExtraBuilder, index: u32, value: anytype) void {
        const T = @TypeOf(value);
        const info = @typeInfo(T).@"struct";
        assert(index + info.field_names.len <= builder.count());
        inline for (info.field_names, 0..) |name, offset| {
            builder.words.items[index + offset] = to_word(@field(value, name));
        }
        assert(std.meta.eql(get(T, builder.words.items, index).data, value));
    }
};

pub fn Decoded(comptime T: type) type {
    comptime assert(@typeInfo(T) == .@"struct");
    comptime assert(@typeInfo(T).@"struct".field_names.len > 0);
    return struct {
        data: T,
        /// The index just past the struct: where a tail written with `add_slice` starts.
        end: u32,
    };
}

/// Reads a `T` stored at `index`.
pub fn get(comptime T: type, words: []const u32, index: u32) Decoded(T) {
    const info = @typeInfo(T).@"struct";
    assert(index + info.field_names.len <= words.len);
    var data: T = undefined;
    inline for (info.field_names, info.field_types, 0..) |name, Field, offset| {
        @field(data, name) = from_word(Field, words[index + offset]);
    }
    const end: u32 = index + @as(u32, @intCast(info.field_names.len));
    assert(end <= words.len);
    return .{ .data = data, .end = end };
}

/// Whether the words at `index` decode as a `T`: each bool word is 0 or 1, and each enum
/// word fits its tag type and, for a closed enum, names a value. Checking untrusted data
/// (program images, P10.5) calls this before `get`, which asserts it.
pub fn decodable(comptime T: type, words: []const u32, index: u32) bool {
    const info = @typeInfo(T).@"struct";
    if (index > words.len or info.field_names.len > words.len - index) return false;
    inline for (info.field_types, 0..) |Field, offset| {
        if (!word_decodes(Field, words[index + offset])) return false;
    }
    assert(index + info.field_names.len <= words.len);
    return true;
}

fn word_decodes(comptime Field: type, word: u32) bool {
    comptime assert(fits_a_word(Field));
    switch (@typeInfo(Field)) {
        .int, .float, .@"struct" => return true,
        .bool => return word <= 1,
        .@"enum" => |enumeration| {
            const tag = std.math.cast(enumeration.tag_type, word) orelse return false;
            if (enumeration.mode == .nonexhaustive) return true;
            return std.enums.fromInt(Field, tag) != null;
        },
        else => comptime unreachable,
    }
}

fn fields_count(comptime T: type) u32 {
    const info = @typeInfo(T).@"struct";
    comptime assert(info.layout != .@"packed");
    inline for (info.field_types) |Field| comptime assert(fits_a_word(Field));
    assert(info.field_names.len > 0);
    return info.field_names.len;
}

fn fits_a_word(comptime Field: type) bool {
    comptime assert(@sizeOf(Field) <= 4);
    comptime assert(@bitSizeOf(Field) <= 32);
    return switch (@typeInfo(Field)) {
        .int => |int| int.bits == 32,
        .float => |float| float.bits == 32,
        .bool => true,
        .@"enum" => |enumeration| @bitSizeOf(enumeration.tag_type) <= 32,
        .@"struct" => |structure| structure.layout == .@"packed" and @bitSizeOf(Field) == 32,
        else => false,
    };
}

fn to_word(value: anytype) u32 {
    const Field = @TypeOf(value);
    comptime assert(fits_a_word(Field));
    const word: u32 = switch (@typeInfo(Field)) {
        .int, .float, .@"struct" => @bitCast(value),
        .bool => @intFromBool(value),
        .@"enum" => @intCast(@backingInt(value)),
        else => comptime unreachable,
    };
    assert(std.meta.eql(from_word(Field, word), value));
    return word;
}

fn from_word(comptime Field: type, word: u32) Field {
    comptime assert(fits_a_word(Field));
    switch (@typeInfo(Field)) {
        .int, .float, .@"struct" => return @bitCast(word),
        .bool => {
            assert(word <= 1);
            return word == 1;
        },
        .@"enum" => |enumeration| {
            const tag: enumeration.tag_type = @intCast(word);
            return @fromBackingInt(@intCast(tag));
        },
        else => comptime unreachable,
    }
}

const StringId = @import("index.zig").StringId;

test "a struct with every field kind and a trailing slice round-trips" {
    // Goal: every supported field kind survives, and the tail is found through `end`.
    // Method: store a struct, then a 3-word tail, and read both back.
    const gpa = std.testing.allocator;
    const Flags = packed struct(u32) { sticky: bool, invisible: bool, rest: u30 = 0 };
    const Kind = enum(u8) { divert, call, tunnel };
    const Record = struct {
        target: u32,
        offset: i32,
        weight: f32,
        once: bool,
        kind: Kind,
        name: StringId,
        flags: Flags,
        tail_count: u32,
    };
    var builder: ExtraBuilder = .{};
    defer builder.deinit(gpa);
    _ = try builder.add_slice(gpa, &.{ 99, 98 }); // Unrelated words before the record.
    const record: Record = .{
        .target = 7,
        .offset = -3,
        .weight = 1.5,
        .once = true,
        .kind = .tunnel,
        .name = StringId.from_int(42),
        .flags = .{ .sticky = true, .invisible = false },
        .tail_count = 3,
    };
    const index = try builder.add(gpa, record);
    _ = try builder.add_slice(gpa, &.{ 10, 20, 30 });
    const decoded = get(Record, builder.words.items, index);
    try std.testing.expectEqual(record, decoded.data);
    const tail = builder.words.items[decoded.end..][0..decoded.data.tail_count];
    try std.testing.expectEqualSlices(u32, &.{ 10, 20, 30 }, tail);
}

test "reserve then set fills a forward reference" {
    // Goal: a struct can be written before its contents are known. Method: reserve, append
    // more words, then set the reserved struct and read it back.
    const gpa = std.testing.allocator;
    const Jump = struct { target: u32, condition: bool };
    var builder: ExtraBuilder = .{};
    defer builder.deinit(gpa);
    const index = try builder.reserve(gpa, Jump);
    _ = try builder.add_slice(gpa, &.{ 1, 2, 3 });
    builder.set(index, Jump{ .target = 5, .condition = true });
    const decoded = get(Jump, builder.words.items, index);
    try std.testing.expectEqual(Jump{ .target = 5, .condition = true }, decoded.data);
    try std.testing.expectEqual(@as(u32, 5), builder.count());
}
