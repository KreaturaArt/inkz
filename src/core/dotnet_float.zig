//! .NET 8's text for a 32-bit float, as ink writes it: `float.ToString(InvariantCulture)`
//! for output and SimpleJson's float for compiled and saved JSON.

const std = @import("std");
const assert = std.debug.assert;

pub const text_bytes_max = 24;

/// Formats `value` as .NET 8's `float.ToString(CultureInfo.InvariantCulture)`: the shortest
/// digits that round-trip, in fixed notation for decimal exponents from -4 to 8 and in
/// scientific notation (`1.5E+09`, `1E-05`) otherwise. Checked against .NET in
/// test/ground_truth/dotnet_floats.expected.
pub fn format(value: f32, buffer: *[text_bytes_max]u8) []const u8 {
    if (std.math.isNan(value)) return copy(buffer, "NaN");
    if (std.math.isInf(value)) return copy(buffer, if (value > 0) "Infinity" else "-Infinity");
    if (value == 0) return copy(buffer, if (std.math.signbit(value)) "-0" else "0");
    // Zig's shortest round-trip digits, as d.ddddde±x.
    var scientific_buffer: [text_bytes_max]u8 = undefined;
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
    return writer.buffered();
}

fn copy(buffer: *[text_bytes_max]u8, text: []const u8) []const u8 {
    assert(text.len <= buffer.len);
    @memcpy(buffer[0..text.len], text);
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
}

fn write_fixed(writer: *std.Io.Writer, digits: []const u8, exponent: i32) !void {
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

/// SimpleJson's float: .NET's text, `.0` when it has no point or exponent, and ink's
/// stand-ins for infinities and NaN.
pub fn write_json(writer: *std.Io.Writer, number: f32) std.Io.Writer.Error!void {
    if (std.math.isNan(number)) return writer.writeAll("0.0");
    if (std.math.isInf(number)) return writer.writeAll(if (number > 0) "3.4E+38" else "-3.4E+38");
    var buffer: [text_bytes_max]u8 = undefined;
    const text = format(number, &buffer);
    try writer.writeAll(text);
    const has_point = std.mem.indexOfAny(u8, text, ".E") != null;
    if (!has_point) try writer.writeAll(".0");
}

test "float formatting matches .NET 8" {
    // Floats print exactly as ink on .NET 8: every value in
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
        var buffer: [text_bytes_max]u8 = undefined;
        const formatted = format(@bitCast(bits), &buffer);
        std.testing.expectEqualStrings(line[9..], formatted) catch |err| {
            std.debug.print("bits {x:0>8}\n", .{bits});
            return err;
        };
        checked += 1;
    }
    try std.testing.expect(checked > 50);
}
