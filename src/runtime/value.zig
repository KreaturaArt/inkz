//! Runtime values (plan §4.3, D14): 12 bytes, scalars exactly as C# ink has them (32-bit
//! wrapping integers, 32-bit floats). Strings and lists live elsewhere (the program's string
//! pool, the state heap, the list slab) and values hold references.

const std = @import("std");
const assert = std.debug.assert;
const index = @import("../core/index.zig");
const limits = @import("../core/limits.zig");
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
        const reference: StringReference = @fromBackingInt(@intCast(raw));
        assert(!reference.is_heap());
        return reference;
    }

    pub fn heap(offset: u32) StringReference {
        assert(offset & heap_bit == 0);
        const reference: StringReference = @fromBackingInt(@intCast(offset | heap_bit));
        assert(reference.is_heap());
        return reference;
    }

    pub fn is_heap(reference: StringReference) bool {
        const raw = @backingInt(reference);
        const result = raw & heap_bit != 0;
        assert(result or raw < heap_bit);
        return result;
    }

    pub fn program_id(reference: StringReference) StringId {
        assert(!reference.is_heap());
        const id = StringId.from_int(@backingInt(reference));
        assert(@backingInt(id) < heap_bit);
        return id;
    }

    pub fn heap_offset(reference: StringReference) u32 {
        assert(reference.is_heap());
        const offset = @backingInt(reference) & ~heap_bit;
        assert(offset < heap_bit);
        return offset;
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
        if (result) |order| assert(order >= -1 and order <= 5);
        return result;
    }

    /// ink's `isTruthy`. Divert targets, variable pointers and tags have no truth value.
    /// `context` provides `list_count(ListReference) u32` and `string_bytes(StringReference)
    /// []const u8`.
    pub fn is_truthy(value: Value, context: anytype) error{NoTruthValue}!bool {
        assert(@typeInfo(@TypeOf(context)) == .pointer);
        return switch (value) {
            .bool => |flag| flag,
            .integer => |number| number != 0,
            .float => |number| number != 0,
            .list => |list| context.list_count(list) > 0,
            .string => |text| context.string_bytes(text).len > 0,
            .null, .divert_target, .variable_pointer, .tag => error.NoTruthValue,
        };
    }
};

comptime {
    assert(@sizeOf(Value) == limits.element_bytes.value);
    assert(@sizeOf(VariablePointer) == 8);
}

pub const float_text_bytes_max = 24;

/// Formats `value` as .NET 8's `float.ToString(CultureInfo.InvariantCulture)`: the shortest
/// digits that round-trip, in fixed notation for decimal exponents from -4 to 8 and in
/// scientific notation (`1.5E+09`, `1E-05`) otherwise. Checked against .NET in
/// test/ground_truth/dotnet_floats.expected.
pub fn format_float(value: f32, buffer: *[float_text_bytes_max]u8) []const u8 {
    if (std.math.isNan(value)) return copy(buffer, "NaN");
    if (std.math.isInf(value)) return copy(buffer, if (value > 0) "Infinity" else "-Infinity");
    if (value == 0) return copy(buffer, if (std.math.signbit(value)) "-0" else "0");
    // Zig's shortest round-trip digits, as d.ddddde±x.
    var scientific_buffer: [float_text_bytes_max]u8 = undefined;
    const scientific = std.fmt.bufPrint(&scientific_buffer, "{e}", .{value}) catch unreachable;
    const exponent_at = std.mem.indexOfScalar(u8, scientific, 'e').?;
    const exponent = std.fmt.parseInt(i32, scientific[exponent_at + 1 ..], 10) catch unreachable;
    const negative = scientific[0] == '-';
    var digits_buffer: [16]u8 = undefined;
    var digits_count: u32 = 0;
    for (scientific[@intFromBool(negative)..exponent_at]) |character| {
        if (character == '.') continue;
        digits_buffer[digits_count] = character;
        digits_count += 1;
    }
    const digits = std.mem.trimEnd(u8, digits_buffer[0..digits_count], "0");
    assert(digits.len > 0);
    var writer: std.Io.Writer = .fixed(buffer);
    if (negative) writer.writeByte('-') catch unreachable;
    if (exponent >= 9 or exponent < -4) {
        write_scientific(&writer, digits, exponent) catch unreachable;
    } else {
        write_fixed(&writer, digits, exponent) catch unreachable;
    }
    assert(writer.end > 0);
    return writer.buffered();
}

fn copy(buffer: *[float_text_bytes_max]u8, text: []const u8) []const u8 {
    assert(text.len <= buffer.len);
    @memcpy(buffer[0..text.len], text);
    assert(text.len > 0);
    return buffer[0..text.len];
}

fn write_scientific(writer: *std.Io.Writer, digits: []const u8, exponent: i32) !void {
    assert(digits.len > 0);
    try writer.writeByte(digits[0]);
    if (digits.len > 1) {
        try writer.writeByte('.');
        try writer.writeAll(digits[1..]);
    }
    const sign: u8 = if (exponent < 0) '-' else '+';
    try writer.print("E{c}{d:0>2}", .{ sign, @abs(exponent) });
    assert(exponent >= 9 or exponent < -4);
}

fn write_fixed(writer: *std.Io.Writer, digits: []const u8, exponent: i32) !void {
    assert(digits.len > 0);
    assert(exponent >= -4 and exponent < 9);
    if (exponent < 0) {
        try writer.writeAll("0.");
        for (0..@as(u32, @intCast(-exponent - 1))) |_| try writer.writeByte('0');
        try writer.writeAll(digits);
        return;
    }
    const whole: u32 = @intCast(exponent + 1);
    if (digits.len <= whole) {
        try writer.writeAll(digits);
        for (0..whole - digits.len) |_| try writer.writeByte('0');
        return;
    }
    try writer.writeAll(digits[0..whole]);
    try writer.writeByte('.');
    try writer.writeAll(digits[whole..]);
}

test "float formatting matches .NET 8" {
    // Goal: plan D17; floats print exactly as ink on .NET 8. Method: every value in
    // test/ground_truth/dotnet_floats.expected, given as raw bits.
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const path = "test/ground_truth/dotnet_floats.expected";
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
    defer gpa.free(text);
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    var checked: u32 = 0;
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        const bits = try std.fmt.parseInt(u32, line[0..8], 16);
        var buffer: [float_text_bytes_max]u8 = undefined;
        const formatted = format_float(@bitCast(bits), &buffer);
        std.testing.expectEqualStrings(line[9..], formatted) catch |err| {
            std.debug.print("bits {x:0>8}\n", .{bits});
            return err;
        };
        checked += 1;
    }
    try std.testing.expect(checked > 50);
}

test "a value is 12 bytes and string references keep their source" {
    // Goal: plan D14 sizes and the pool/heap split. Method: size and round trips.
    try std.testing.expectEqual(12, @sizeOf(Value));
    const in_program = StringReference.program(.from_int(5));
    try std.testing.expect(!in_program.is_heap());
    try std.testing.expectEqual(StringId.from_int(5), in_program.program_id());
    const in_heap = StringReference.heap(1234);
    try std.testing.expect(in_heap.is_heap());
    try std.testing.expectEqual(@as(u32, 1234), in_heap.heap_offset());
}
