//! Test helpers for programs: field-by-field equality (the verified pairs of plan P8.0 and
//! P8.5).

const std = @import("std");
const assert = std.debug.assert;
const Program = @import("program.zig").Program;

/// Whether two programs are the same, field by field.
pub fn expect_same_program(expected: *const Program, actual: *const Program) !void {
    const testing = std.testing;
    assert(expected.containers.len > 0);
    assert(actual.containers.len > 0);
    try testing.expectEqualSlices(u8, expected.strings.strings.bytes, actual.strings.strings.bytes);
    try testing.expectEqualSlices(u32, expected.strings.strings.ends, actual.strings.strings.ends);
    try expect_same_columns(expected.instructions, actual.instructions);
    try expect_same_columns(expected.containers, actual.containers);
    try testing.expectEqualSlices(u32, expected.extra, actual.extra);
    inline for (.{ "named", "globals", "list_origins", "list_items", "externals" }) |field| {
        const left = @field(expected, field);
        const right = @field(actual, field);
        try testing.expectEqual(left.len, right.len);
        for (left, right) |a, b| try testing.expect(std.meta.eql(a, b));
    }
    try testing.expectEqual(expected.global_declaration, actual.global_declaration);
    try testing.expectEqual(expected.count_slots_count, actual.count_slots_count);
}

fn expect_same_columns(expected: anytype, actual: @TypeOf(expected)) !void {
    comptime assert(@TypeOf(expected) == @TypeOf(actual));
    assert(expected.len < std.math.maxInt(u32));
    try std.testing.expectEqual(expected.len, actual.len);
    const Item = @TypeOf(expected.get(0));
    inline for (comptime std.meta.fieldNames(Item)) |name| {
        const column = @field(std.meta.FieldEnum(Item), name);
        for (expected.items(column), actual.items(column)) |a, b| {
            try std.testing.expect(std.meta.eql(a, b));
        }
    }
}
