//! The `extra` side table: records too wide for an instruction operand are stored
//! as consecutive `u32` words, and the instruction keeps their index.
//!
//! A record is an `extern struct` whose fields are each one word: `u32`, `i32`, `f32`, an
//! enum whose tag is 32 bits (index newtypes included), or a `packed struct(u32)` (flags), so
//! it is stored and read back as its words, with one `@ptrCast`. A variable-length tail
//! follows with `add_slice`, at `index + words(T)`.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub const ExtraBuilder = struct {
    words: std.ArrayList(u32) = .empty,

    pub fn deinit(builder: *ExtraBuilder, gpa: Allocator) void {
        builder.words.deinit(gpa);
        builder.* = undefined;
    }

    pub fn count(builder: *const ExtraBuilder) u32 {
        const words_count: u32 = @intCast(builder.words.items.len);
        assert(words_count == builder.words.items.len);
        return words_count;
    }

    /// Appends `value` and returns the index of its first word.
    pub fn add(builder: *ExtraBuilder, gpa: Allocator, value: anytype) !u32 {
        const record: *const [words(@TypeOf(value))]u32 = @ptrCast(&value);
        return builder.add_slice(gpa, record);
    }

    /// Appends a variable-length tail of words and returns the index of the first one.
    pub fn add_slice(builder: *ExtraBuilder, gpa: Allocator, tail: []const u32) !u32 {
        const index = builder.count();
        if (tail.len > std.math.maxInt(u32) - index) return error.ExtraFull;
        try builder.words.appendSlice(gpa, tail);
        assert(builder.count() == index + tail.len);
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
};

/// How many words a `T` takes: one per field.
pub fn words(comptime T: type) u32 {
    return comptime count: {
        const info = @typeInfo(T).@"struct";
        assert(info.layout == .@"extern");
        assert(info.field_names.len > 0);
        for (info.field_types) |Field| {
            assert(@sizeOf(Field) == 4);
            const flags = @typeInfo(Field) == .@"struct";
            assert(!flags or @typeInfo(Field).@"struct".layout == .@"packed");
        }
        assert(@sizeOf(T) == 4 * info.field_names.len);
        break :count info.field_names.len;
    };
}

/// Reads the `T` stored at `index`, which must be `decodable`.
pub fn get(comptime T: type, extra: []const u32, index: u32) T {
    assert(decodable(T, extra, index));
    const record: *const T = @ptrCast(extra[index..][0..words(T)]);
    return record.*;
}

/// Whether the words at `index` decode as a `T`: each enum word fits its tag type and, for a
/// closed enum, names a value, and each flags word's padding is zero. Checking untrusted data
/// (program images) calls this before `get`, which asserts it.
pub fn decodable(comptime T: type, extra: []const u32, index: u32) bool {
    const info = @typeInfo(T).@"struct";
    if (index > extra.len or words(T) > extra.len - index) return false;
    inline for (info.field_types, 0..) |Field, offset| {
        const word = extra[index + offset];
        switch (@typeInfo(Field)) {
            .int, .float => {},
            .@"struct" => if (!flags_decode(Field, word)) return false,
            .@"enum" => if (!enum_decodes(Field, word)) return false,
            else => comptime unreachable,
        }
    }
    return true;
}

fn enum_decodes(comptime Field: type, word: u32) bool {
    const enumeration = @typeInfo(Field).@"enum";
    const tag = std.math.cast(enumeration.tag_type, word) orelse return false;
    if (enumeration.mode == .nonexhaustive) return true;
    return std.enums.fromInt(Field, tag) != null;
}

/// A packed struct's bit fields: an enum field must name a value (a closed `enum(u2)` with
/// three values has a fourth bit pattern), `padding` must be zero, the rest are any bits.
fn flags_decode(comptime Field: type, word: u32) bool {
    const structure = @typeInfo(Field).@"struct";
    comptime assert(structure.layout == .@"packed");
    inline for (structure.field_names, structure.field_types) |name, Bits| {
        comptime assert(@bitSizeOf(Bits) < 32);
        const mask: u32 = (@as(u32, 1) << @bitSizeOf(Bits)) - 1;
        const bits = (word >> @bitOffsetOf(Field, name)) & mask;
        if (@typeInfo(Bits) == .@"enum") {
            if (!enum_decodes(Bits, bits)) return false;
        } else if (comptime std.mem.eql(u8, name, "padding")) {
            if (bits != 0) return false;
        } else {
            comptime assert(@typeInfo(Bits) == .int or @typeInfo(Bits) == .bool);
        }
    }
    return true;
}

const StringId = @import("index.zig").StringId;
const instruction = @import("instruction.zig");

test "a record with every field kind and a trailing slice round-trips" {
    // Every supported field kind survives, and the tail starts at `index + words(T)`.
    // Store a record after unrelated words, then a 3-word tail, and read both back.
    const gpa = std.testing.allocator;
    const Flags = packed struct(u32) { sticky: bool, invisible: bool, padding: u30 = 0 };
    const Kind = enum(u32) { divert, call, tunnel };
    const Record = extern struct {
        target: u32,
        offset: i32,
        weight: f32,
        kind: Kind,
        name: StringId,
        flags: Flags,
        tail_count: u32,
    };
    var builder: ExtraBuilder = .{};
    defer builder.deinit(gpa);
    _ = try builder.add_slice(gpa, &.{ 99, 98 });
    const record: Record = .{
        .target = 7,
        .offset = -3,
        .weight = 1.5,
        .kind = .tunnel,
        .name = StringId.from_int(42),
        .flags = .{ .sticky = true, .invisible = false },
        .tail_count = 3,
    };
    const index = try builder.add(gpa, record);
    try std.testing.expectEqual(@as(u32, 2), index);
    _ = try builder.add_slice(gpa, &.{ 10, 20, 30 });
    try std.testing.expectEqual(record, get(Record, builder.words.items, index));
    const tail = builder.words.items[index + words(Record) ..][0..record.tail_count];
    try std.testing.expectEqualSlices(u32, &.{ 10, 20, 30 }, tail);
    const reserved = try builder.reserve_words(gpa, 2);
    try std.testing.expectEqualSlices(u32, &.{ 0, 0 }, builder.words.items[reserved..]);
}

test "every instruction record round-trips through its words" {
    // Each record type the builder stores, with distinct field values, comes back equal.
    const gpa = std.testing.allocator;
    var builder: ExtraBuilder = .{};
    defer builder.deinit(gpa);
    const records = .{
        instruction.Divert{
            .target_container = .from_int(3),
            .target_index = 4,
            .name = .from_int(5),
            .flags = .{ .kind = .tunnel, .conditional = true, .variable = false },
        },
        instruction.ExternalCall{
            .external = .from_int(6),
            .arguments_count = 2,
            .flags = .{ .conditional = true },
        },
        instruction.ChoicePoint{
            .target_container = .from_int(7),
            .target_index = 8,
            .flags = .{
                .has_condition = true,
                .has_start_content = false,
                .has_choice_only_content = true,
                .is_invisible_default = false,
                .once_only = true,
            },
        },
        instruction.VariablePointer{ .name = .from_int(9), .context = -1 },
        instruction.ListLiteral{ .items_count = 10, .origins_count = 11 },
    };
    inline for (records) |record| {
        const index = try builder.add(gpa, record);
        try std.testing.expectEqual(builder.count(), index + words(@TypeOf(record)));
        try std.testing.expectEqual(record, get(@TypeOf(record), builder.words.items, index));
    }
}

test "decodable rejects an enum bit pattern that names no value, and flags padding" {
    // Program images are untrusted: a closed enum(u2) with three values has a fourth
    // pattern, which `get` would turn into illegal behaviour. Check a plain enum word and the
    // same enum as a packed field, with the bad pattern and with every good one; then set
    // padding bits, and read past the end.
    const Kind = enum(u2) { plain, function, tunnel };
    const Wide = enum(u32) { plain, function, tunnel };
    const Flags = packed struct(u32) { kind: Kind, conditional: bool, padding: u29 = 0 };
    const Record = extern struct { flags: Flags };
    const Plain = extern struct { kind: Wide };
    for (0..4) |pattern| {
        const good = pattern < 3;
        const flag_word: u32 = @as(u32, @intCast(pattern)) | (1 << 2);
        try std.testing.expectEqual(good, decodable(Record, &.{flag_word}, 0));
        try std.testing.expectEqual(good, decodable(Plain, &.{@intCast(pattern)}, 0));
    }
    try std.testing.expect(!decodable(Plain, &.{1 << 8}, 0));
    try std.testing.expect(!decodable(Record, &.{1 << 3}, 0));
    try std.testing.expect(!decodable(Record, &.{0}, 1));
}
