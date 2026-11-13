//! ink's native functions (plan P4.1), following ink's NativeFunctionCall.cs: both operands
//! are coerced to the higher of their two types (bool < int < float < list < string, starting
//! from int so bools always become ints), then the operation for that type runs.
//!
//! Integers wrap like C#'s unchecked arithmetic. Division and modulo by zero, `minInt / -1`
//! and converting NaN or an out-of-range float to an int are story errors (D18). Lists are
//! handled by the list slab (P4.2) through `context`.
//!
//! `context` provides `string_bytes(StringReference) []const u8`,
//! `string_concat([]const u8, []const u8) !StringReference` and `list_count(ListReference)
//! u32`; list operations also need `list_binary(Opcode, Value, Value) !Value` and
//! `list_unary(Opcode, Value) !Value`.

const std = @import("std");
const assert = std.debug.assert;
const value_module = @import("value.zig");
const Opcode = @import("../core/instruction.zig").Opcode;
const Value = value_module.Value;
const StringReference = value_module.StringReference;

pub const Error = error{
    DivisionByZero,
    IntegerOverflow,
    FloatToIntegerOutOfRange,
    /// An operand is `void`: ink's "did you forget to return a value?".
    VoidOperand,
    /// The operation doesn't exist for this type, like `*` on strings.
    UnsupportedOperation,
    /// The operands can't be coerced to one type, like a divert target and an int.
    IncompatibleTypes,
    ListLimit,
    HeapLimit,
};

const Kind = enum { integer, float, string, list, divert_target };

/// The type both operands of a binary operation become.
fn common_kind(a: Value, b: Value) Error!Kind {
    assert(a != .null and b != .null);
    const rank_a = a.rank() orelse return error.VoidOperand;
    const rank_b = b.rank() orelse return error.VoidOperand;
    const rank = @max(@as(i8, 0), rank_a, rank_b);
    const kind: Kind = switch (rank) {
        0 => .integer,
        1 => .float,
        2 => .list,
        3 => .string,
        4 => .divert_target,
        else => return error.IncompatibleTypes,
    };
    assert(rank >= 0);
    return kind;
}

fn to_integer(value: Value) Error!i32 {
    assert(value != .null);
    const result: i32 = switch (value) {
        .integer => |number| number,
        .bool => |flag| @intFromBool(flag),
        else => return error.IncompatibleTypes,
    };
    assert(value == .integer or result <= 1);
    return result;
}

fn to_float(value: Value) Error!f32 {
    assert(value != .null);
    const result: f32 = switch (value) {
        .float => |number| number,
        .integer => |number| @floatFromInt(number),
        .bool => |flag| if (flag) 1 else 0,
        else => return error.IncompatibleTypes,
    };
    assert(value != .bool or result == 0 or result == 1);
    return result;
}

/// A value's text for string operations, formatted into `buffer` when it isn't a string.
fn to_text(context: anytype, value: Value, buffer: *[32]u8) Error![]const u8 {
    assert(buffer.len >= value_module.float_text_bytes_max);
    const text: []const u8 = switch (value) {
        .string => |reference| context.string_bytes(reference),
        .integer => |number| std.fmt.bufPrint(buffer, "{d}", .{number}) catch unreachable,
        .float => |number| format: {
            const float_buffer = buffer[0..value_module.float_text_bytes_max];
            break :format value_module.format_float(number, float_buffer);
        },
        .bool => |flag| if (flag) "true" else "false",
        else => return error.IncompatibleTypes,
    };
    assert(value == .string or text.len > 0);
    return text;
}

/// A binary native function: arithmetic, comparison, logic, MIN/MAX/POW, and list and
/// string membership.
pub fn binary(context: anytype, opcode: Opcode, a: Value, b: Value) Error!Value {
    assert(@backingInt(opcode) >= @backingInt(Opcode.add));
    if (a == .null or b == .null) return error.VoidOperand;
    if (a == .list or b == .list) {
        // Lists aren't coerced the normal way; `&&` and `||` with a non-list use truth values.
        if ((opcode == .@"and" or opcode == .@"or") and (a != .list or b != .list)) {
            const left = a.is_truthy(context) catch return error.IncompatibleTypes;
            const right = b.is_truthy(context) catch return error.IncompatibleTypes;
            return .{ .bool = if (opcode == .@"and") left and right else left or right };
        }
        return context.list_binary(opcode, a, b);
    }
    const result = switch (try common_kind(a, b)) {
        .integer => try numeric_binary(i32, opcode, try to_integer(a), try to_integer(b)),
        .float => try numeric_binary(f32, opcode, try to_float(a), try to_float(b)),
        .string => try string_binary(context, opcode, a, b),
        .divert_target => try divert_binary(opcode, a, b),
        .list => unreachable,
    };
    assert(result != .null);
    return result;
}

/// An i32 or f32 as a value.
fn number_value(number: anytype) Value {
    return switch (@TypeOf(number)) {
        i32 => .{ .integer = number },
        f32 => .{ .float = number },
        else => comptime unreachable,
    };
}

/// Arithmetic, comparison and logic on two integers or two floats. Integers wrap; floats
/// take C#'s Math.Max and Math.Min.
fn numeric_binary(comptime T: type, opcode: Opcode, a: T, b: T) Error!Value {
    comptime assert(T == i32 or T == f32);
    const integer = T == i32;
    const result: Value = switch (opcode) {
        .add => number_value(if (integer) a +% b else a + b),
        .subtract => number_value(if (integer) a -% b else a - b),
        .multiply => number_value(if (integer) a *% b else a * b),
        .divide => number_value(if (integer) try integer_divide(a, b) else a / b),
        .modulo => number_value(if (integer) try integer_modulo(a, b) else @rem(a, b)),
        .equal => .{ .bool = a == b },
        .not_equal => .{ .bool = a != b },
        .greater => .{ .bool = a > b },
        .less => .{ .bool = a < b },
        .greater_or_equal => .{ .bool = a >= b },
        .less_or_equal => .{ .bool = a <= b },
        .@"and" => .{ .bool = a != 0 and b != 0 },
        .@"or" => .{ .bool = a != 0 or b != 0 },
        .max => number_value(if (integer) @max(a, b) else maximum(a, b)),
        .min => number_value(if (integer) @min(a, b) else minimum(a, b)),
        // ink casts integers to float, since POW(2, -1) is a fraction.
        .pow => .{ .float = if (integer) pow(@floatFromInt(a), @floatFromInt(b)) else pow(a, b) },
        else => return error.UnsupportedOperation,
    };
    assert(result != .null);
    return result;
}

fn integer_divide(a: i32, b: i32) Error!i32 {
    if (b == 0) return error.DivisionByZero;
    if (a == std.math.minInt(i32) and b == -1) return error.IntegerOverflow;
    const result = @divTrunc(a, b);
    assert(@abs(result) <= @abs(a));
    return result;
}

fn integer_modulo(a: i32, b: i32) Error!i32 {
    if (b == 0) return error.DivisionByZero;
    // .NET throws for this one too.
    if (a == std.math.minInt(i32) and b == -1) return error.IntegerOverflow;
    const result = @rem(a, b);
    assert(@abs(result) < @abs(b));
    return result;
}

/// `(float)Math.Pow(x, y)`: computed in double precision, then rounded.
fn pow(x: f32, y: f32) f32 {
    const result: f32 = @floatCast(std.math.pow(f64, x, y));
    assert(!std.math.isNan(result) or std.math.isNan(x) or std.math.isNan(y) or x < 0);
    return result;
}

/// C#'s Math.Max(float, float): NaN if either is NaN, and +0 over -0.
fn maximum(a: f32, b: f32) f32 {
    if (std.math.isNan(a) or std.math.isNan(b)) return std.math.nan(f32);
    if (a == b) return if (std.math.signbit(a)) b else a;
    const result = if (a > b) a else b;
    assert(result >= a and result >= b);
    return result;
}

/// C#'s Math.Min(float, float): NaN if either is NaN, and -0 over +0.
fn minimum(a: f32, b: f32) f32 {
    if (std.math.isNan(a) or std.math.isNan(b)) return std.math.nan(f32);
    if (a == b) return if (std.math.signbit(a)) a else b;
    const result = if (a < b) a else b;
    assert(result <= a and result <= b);
    return result;
}

fn string_binary(context: anytype, opcode: Opcode, a: Value, b: Value) Error!Value {
    assert(a == .string or b == .string);
    var buffer_a: [32]u8 = undefined;
    var buffer_b: [32]u8 = undefined;
    const text_a = try to_text(context, a, &buffer_a);
    const text_b = try to_text(context, b, &buffer_b);
    const result: Value = switch (opcode) {
        .add => .{ .string = try context.string_concat(text_a, text_b) },
        .equal => .{ .bool = std.mem.eql(u8, text_a, text_b) },
        .not_equal => .{ .bool = !std.mem.eql(u8, text_a, text_b) },
        .has => .{ .bool = std.mem.indexOf(u8, text_a, text_b) != null },
        .hasnt => .{ .bool = std.mem.indexOf(u8, text_a, text_b) == null },
        else => return error.UnsupportedOperation,
    };
    assert(result == .string or result == .bool);
    return result;
}

fn divert_binary(opcode: Opcode, a: Value, b: Value) Error!Value {
    assert(a == .divert_target or b == .divert_target);
    if (a != .divert_target or b != .divert_target) return error.IncompatibleTypes;
    const same = a.divert_target == b.divert_target;
    const result: Value = switch (opcode) {
        .equal => .{ .bool = same },
        .not_equal => .{ .bool = !same },
        else => return error.UnsupportedOperation,
    };
    assert(result == .bool);
    return result;
}

/// A unary native function: negate, not, FLOOR, CEILING, INT, FLOAT and the list functions.
pub fn unary(context: anytype, opcode: Opcode, a: Value) Error!Value {
    assert(@backingInt(opcode) >= @backingInt(Opcode.add));
    if (a == .null) return error.VoidOperand;
    if (a == .list) return context.list_unary(opcode, a);
    const result: Value = switch (a) {
        .bool, .integer => try numeric_unary(i32, opcode, try to_integer(a)),
        .float => |number| try numeric_unary(f32, opcode, number),
        else => return error.UnsupportedOperation,
    };
    assert(result != .null);
    return result;
}

fn numeric_unary(comptime T: type, opcode: Opcode, a: T) Error!Value {
    comptime assert(T == i32 or T == f32);
    const integer = T == i32;
    const result: Value = switch (opcode) {
        .negate => number_value(if (integer) -%a else -a),
        .not => .{ .bool = a == 0 },
        .floor => number_value(if (integer) a else @floor(a)),
        .ceiling => number_value(if (integer) a else @ceil(a)),
        .int => .{ .integer = if (integer) a else try float_to_integer(a) },
        .float_cast => .{ .float = if (integer) @floatFromInt(a) else a },
        else => return error.UnsupportedOperation,
    };
    assert(result != .null);
    return result;
}

/// `(int)x`, truncating. Out of range or NaN is a story error (D18): .NET's answer depends on
/// the processor, so inkz refuses instead of guessing.
pub fn float_to_integer(a: f32) Error!i32 {
    if (std.math.isNan(a)) return error.FloatToIntegerOutOfRange;
    const truncated = @trunc(a);
    if (truncated < -2147483648.0 or truncated >= 2147483648.0) {
        return error.FloatToIntegerOutOfRange;
    }
    const result: i32 = @intFromFloat(truncated);
    assert(@as(f64, @floatFromInt(result)) == truncated);
    return result;
}

/// A context with strings in a small arena, for the tests; it has no lists.
const TestContext = struct {
    strings: std.ArrayList([]const u8) = .empty,
    arena: std.heap.ArenaAllocator,

    pub fn string_bytes(context: *TestContext, reference: StringReference) []const u8 {
        assert(reference.is_heap());
        const offset = reference.heap_offset();
        assert(offset < context.strings.items.len);
        return context.strings.items[offset];
    }

    fn string_concat(context: *TestContext, a: []const u8, b: []const u8) Error!StringReference {
        assert(a.len + b.len < 1 << 20);
        const allocator = context.arena.allocator();
        const text = std.mem.concat(allocator, u8, &.{ a, b }) catch return error.HeapLimit;
        context.strings.append(allocator, text) catch return error.HeapLimit;
        assert(text.len == a.len + b.len);
        return .heap(@intCast(context.strings.items.len - 1));
    }

    fn string_value(context: *TestContext, text: []const u8) !Value {
        assert(context.strings.items.len < 1 << 20);
        assert(text.len < 1024);
        return .{ .string = try context.string_concat(text, "") };
    }

    // This context has no lists: list operations are P4.2.
    pub fn list_count(context: *TestContext, list: value_module.ListReference) u32 {
        assert(context.strings.items.len < 1 << 20);
        assert(@backingInt(list) < 1 << 31);
        return 0;
    }

    fn list_binary(context: *TestContext, opcode: Opcode, a: Value, b: Value) Error!Value {
        assert(a == .list or b == .list);
        assert(@backingInt(opcode) > 0 and context.strings.items.len < 1 << 20);
        return error.UnsupportedOperation;
    }

    fn list_unary(context: *TestContext, opcode: Opcode, a: Value) Error!Value {
        assert(a == .list);
        assert(@backingInt(opcode) > 0 and context.strings.items.len < 1 << 20);
        return error.UnsupportedOperation;
    }
};

fn test_context() TestContext {
    const context: TestContext = .{ .arena = .init(std.testing.allocator) };
    assert(context.strings.items.len == 0);
    assert(context.arena.queryCapacity() == 0);
    return context;
}

test "integer arithmetic wraps like C# and faults where C# throws" {
    // Goal: D14 and D18. Method: overflow on each operator, then the faulting cases.
    var context = test_context();
    defer context.arena.deinit();
    const max: Value = .{ .integer = std.math.maxInt(i32) };
    const min: Value = .{ .integer = std.math.minInt(i32) };
    const one: Value = .{ .integer = 1 };
    const minus_one: Value = .{ .integer = -1 };
    const zero: Value = .{ .integer = 0 };
    try std.testing.expectEqual(min, try binary(&context, .add, max, one));
    try std.testing.expectEqual(max, try binary(&context, .subtract, min, one));
    try std.testing.expectEqual(min, try unary(&context, .negate, min));
    try std.testing.expectEqual(
        Value{ .integer = -3 },
        try binary(&context, .divide, .{ .integer = -7 }, .{ .integer = 2 }),
    );
    try std.testing.expectEqual(
        Value{ .integer = -1 },
        try binary(&context, .modulo, .{ .integer = -7 }, .{ .integer = 2 }),
    );
    try std.testing.expectError(error.DivisionByZero, binary(&context, .divide, one, zero));
    try std.testing.expectError(error.DivisionByZero, binary(&context, .modulo, one, zero));
    try std.testing.expectError(error.IntegerOverflow, binary(&context, .divide, min, minus_one));
    try std.testing.expectError(error.IntegerOverflow, binary(&context, .modulo, min, minus_one));
}

test "coercion follows ink's order" {
    // Goal: bool < int < float < string. Method: mixed operands for each step.
    var context = test_context();
    defer context.arena.deinit();
    const yes: Value = .{ .bool = true };
    try std.testing.expectEqual(Value{ .integer = 2 }, try binary(&context, .add, yes, yes));
    try std.testing.expectEqual(Value{ .bool = true }, try binary(&context, .equal, yes, .{
        .integer = 1,
    }));
    try std.testing.expectEqual(
        Value{ .float = 2.5 },
        try binary(&context, .add, .{ .integer = 2 }, .{ .float = 0.5 }),
    );
    try std.testing.expectEqual(
        Value{ .bool = true },
        try binary(&context, .equal, .{ .integer = 2 }, .{ .float = 2 }),
    );
    const five = try context.string_value("5");
    try std.testing.expectEqual(Value{ .bool = true }, try binary(&context, .equal, five, .{
        .integer = 5,
    }));
    const joined = try binary(&context, .add, try context.string_value("x = "), .{ .float = 2.5 });
    try std.testing.expectEqualStrings("x = 2.5", context.string_bytes(joined.string));
    const with_bool = try binary(&context, .add, try context.string_value("is "), yes);
    try std.testing.expectEqualStrings("is true", context.string_bytes(with_bool.string));
    try std.testing.expectError(
        error.IncompatibleTypes,
        binary(&context, .add, .{ .divert_target = .from_int(1) }, .{ .integer = 1 }),
    );
    try std.testing.expectError(error.VoidOperand, binary(&context, .add, .null, .{
        .integer = 1,
    }));
}

test "float operations follow C#" {
    // Goal: float semantics (D14). Method: modulo, MIN/MAX with NaN and signed zero, POW,
    // FLOOR/CEILING, and INT with its faults.
    var context = test_context();
    defer context.arena.deinit();
    try std.testing.expectEqual(
        Value{ .float = -1.5 },
        try binary(&context, .modulo, .{ .float = -7.5 }, .{ .float = 3 }),
    );
    const nan_max = try binary(&context, .max, .{ .float = std.math.nan(f32) }, .{ .float = 1 });
    try std.testing.expect(std.math.isNan(nan_max.float));
    const zero_max = try binary(&context, .max, .{ .float = -0.0 }, .{ .float = 0.0 });
    try std.testing.expect(!std.math.signbit(zero_max.float));
    try std.testing.expectEqual(
        Value{ .float = 0.5 },
        try binary(&context, .pow, .{ .integer = 2 }, .{ .integer = -1 }),
    );
    try std.testing.expectEqual(Value{ .float = -3 }, try unary(&context, .floor, .{
        .float = -2.5,
    }));
    try std.testing.expectEqual(Value{ .integer = -2 }, try unary(&context, .int, .{
        .float = -2.9,
    }));
    try std.testing.expectError(error.FloatToIntegerOutOfRange, unary(&context, .int, .{
        .float = std.math.nan(f32),
    }));
    try std.testing.expectError(error.FloatToIntegerOutOfRange, unary(&context, .int, .{
        .float = 3e9,
    }));
    try std.testing.expectEqual(
        Value{ .float = std.math.inf(f32) },
        try binary(&context, .divide, .{ .float = 1 }, .{ .float = 0 }),
    );
}

test "logic and string membership" {
    // Goal: truth values and `?`/`!?` on strings. Method: a few combinations.
    var context = test_context();
    defer context.arena.deinit();
    try std.testing.expectEqual(Value{ .bool = false }, try unary(&context, .not, .{
        .integer = 3,
    }));
    try std.testing.expectEqual(
        Value{ .bool = true },
        try binary(&context, .@"or", .{ .integer = 0 }, .{ .float = 0.5 }),
    );
    const haystack = try context.string_value("hello world");
    try std.testing.expectEqual(
        Value{ .bool = true },
        try binary(&context, .has, haystack, try context.string_value("o w")),
    );
    try std.testing.expectEqual(
        Value{ .bool = true },
        try binary(&context, .hasnt, haystack, try context.string_value("xyz")),
    );
    try std.testing.expectError(
        error.UnsupportedOperation,
        binary(&context, .multiply, haystack, haystack),
    );
}
