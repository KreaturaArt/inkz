//! Runtime values: 12 bytes, scalars exactly as C# ink has them (32-bit
//! wrapping integers, 32-bit floats). Strings and lists live elsewhere (the program's string
//! pool, the state heap, the list slab) and values hold references.

const std = @import("std");
const assert = std.debug.assert;
const index = @import("../core/index.zig");
const limits = @import("../core/limits.zig");
const dotnet_float = @import("../core/dotnet_float.zig");
const ContainerIndex = index.ContainerIndex;
const StringId = index.StringId;

/// A string in the program's pool or in the state heap. The high bit selects the heap.
pub const StringReference = enum(u32) {
    _,

    const heap_bit: u32 = 1 << 31;

    /// No string: not a heap reference, and past every program string id.
    pub const none: StringReference = @fromBackingInt(heap_bit - 1);

    pub fn program(id: StringId) StringReference {
        const raw = id.to_int();
        assert(raw & heap_bit == 0);
        return @fromBackingInt(@intCast(raw));
    }

    pub fn heap(offset: u32) StringReference {
        assert(offset & heap_bit == 0);
        return @fromBackingInt(@intCast(offset | heap_bit));
    }

    pub fn is_heap(reference: StringReference) bool {
        const raw = @backingInt(reference);
        return raw & heap_bit != 0;
    }

    pub fn program_id(reference: StringReference) StringId {
        assert(!reference.is_heap());
        return StringId.from_int(@backingInt(reference));
    }

    pub fn heap_offset(reference: StringReference) u32 {
        assert(reference.is_heap());
        return @backingInt(reference) & ~heap_bit;
    }
};

/// A list value in the state's list slab.
pub const ListReference = enum(u32) { _ };

pub const VariablePointer = struct {
    name: StringId,
    /// ink's context index: -1 unknown, 0 global, n > 0 a call-stack frame.
    context: i32,
};

pub const Value = union(enum(u8)) {
    null,
    integer: i32,
    float: f32,
    bool: bool,
    string: StringReference,
    divert_target: ContainerIndex,
    variable_pointer: VariablePointer,
    list: ListReference,
    /// A v21 tag on the evaluation stack.
    tag: StringReference,

    pub const Tag = std.meta.Tag(Value);

    /// ink's coercion order (Value.cs `ValueType`): a binary operation converts both operands
    /// to the higher of their two types. Null and tags don't take part in arithmetic.
    pub fn rank(value: Value) ?i8 {
        const result: ?i8 = switch (value) {
            .bool => -1,
            .integer => 0,
            .float => 1,
            .list => 2,
            .string => 3,
            .divert_target => 4,
            .variable_pointer => 5,
            .null, .tag => null,
        };
        return result;
    }

    /// ink's `isTruthy`. Divert targets, variable pointers and tags have no truth value.
    /// `context` provides `list_count(ListReference) u32` and `string_bytes(StringReference)
    /// []const u8`.
    pub fn is_truthy(value: Value, context: anytype) error{NoTruthValue}!bool {
        return switch (value) {
            .bool => |flag| flag,
            .integer => |number| number != 0,
            .float => |number| number != 0,
            .list => |list| context.list_count(list) > 0,
            .string => |text| context.string_bytes(text).len > 0,
            .null, .divert_target, .variable_pointer, .tag => error.NoTruthValue,
        };
    }

    /// Same tag and same payload: strings and lists by reference, floats by their bits (0.0
    /// and -0.0 differ, a NaN equals itself), so what is identical restores exactly. ink's
    /// "same value object" test for observers; ink's value equality is `values_equal` in
    /// story.zig, by text and by list items.
    pub fn identical(a: Value, b: Value) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .float => |number| @as(u32, @bitCast(number)) == @as(u32, @bitCast(b.float)),
            else => std.meta.eql(a, b),
        };
    }
};

comptime {
    assert(@sizeOf(Value) == limits.element_bytes.value);
    assert(@sizeOf(VariablePointer) == 8);
}

/// .NET's float text lives in core, which the compiler's JSON writer shares.
pub const float_text_bytes_max = dotnet_float.text_bytes_max;
pub const format_float = dotnet_float.format;

test "a value is 12 bytes and string references keep their source" {
    // Sizes and the pool/heap split: size and round trips.
    try std.testing.expectEqual(12, @sizeOf(Value));
    const in_program = StringReference.program(.from_int(5));
    try std.testing.expect(!in_program.is_heap());
    try std.testing.expectEqual(StringId.from_int(5), in_program.program_id());
    const in_heap = StringReference.heap(1234);
    try std.testing.expect(in_heap.is_heap());
    try std.testing.expectEqual(@as(u32, 1234), in_heap.heap_offset());
}

test "identical values have the same tag and payload, floats by their bits" {
    // Observers and shared choice snapshots compare by identity: -0.0 is not 0.0, a NaN is
    // itself, strings compare by reference and an integer is never a float.
    const nan = std.math.nan(f32);
    try std.testing.expect((Value{ .float = nan }).identical(.{ .float = nan }));
    try std.testing.expect(!(Value{ .float = 0.0 }).identical(.{ .float = -0.0 }));
    try std.testing.expect(!(Value{ .integer = 1 }).identical(.{ .float = 1.0 }));
    const text: Value = .{ .string = .heap(4) };
    try std.testing.expect(text.identical(.{ .string = .heap(4) }));
    try std.testing.expect(!text.identical(.{ .string = .heap(8) }));
    const pointer: Value = .{ .variable_pointer = .{ .name = .from_int(3), .context = 0 } };
    try std.testing.expect(pointer.identical(pointer));
    try std.testing.expect(!pointer.identical(.{ .variable_pointer = .{
        .name = .from_int(3),
        .context = 1,
    } }));
}
