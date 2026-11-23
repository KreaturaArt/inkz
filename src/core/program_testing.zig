//! Program equality, field by field: for tests and for the swarm's round trips.

// lint: allow assertion_density: comparisons that name a difference; nothing to assert.

const std = @import("std");
const Program = @import("program.zig").Program;

/// The name of the first field in which two programs differ (every array, element by
/// element, and every scalar), or null when they are the same.
pub fn first_difference(expected: *const Program, actual: *const Program) ?[]const u8 {
    if (!std.mem.eql(u8, expected.strings.bytes.items, actual.strings.bytes.items)) {
        return "strings.bytes";
    }
    if (!std.mem.eql(u32, expected.strings.ends.items, actual.strings.ends.items)) {
        return "strings.ends";
    }
    if (!same_columns(expected.instructions, actual.instructions)) return "instructions";
    if (!same_columns(expected.containers, actual.containers)) return "containers";
    if (!std.mem.eql(u32, expected.extra, actual.extra)) return "extra";
    const arrays = .{ "name_classes", "named", "globals", "list_origins", "list_items" };
    inline for (arrays ++ .{"externals"}) |field| {
        if (!same_items(@field(expected, field), @field(actual, field))) return field;
    }
    inline for (.{ "global_declaration", "count_slots_count", "ink_version", "newline" }) |field| {
        if (@field(expected, field) != @field(actual, field)) return field;
    }
    return null;
}

/// Fails (naming the field) when two programs differ.
pub fn expect_same_program(expected: *const Program, actual: *const Program) !void {
    const field = first_difference(expected, actual) orelse return;
    std.debug.print("programs differ in {s}\n", .{field});
    return error.TestExpectedEqual;
}

fn same_items(expected: anytype, actual: @TypeOf(expected)) bool {
    if (expected.len != actual.len) return false;
    for (expected, actual) |a, b| if (!std.meta.eql(a, b)) return false;
    return true;
}

fn same_columns(expected: anytype, actual: @TypeOf(expected)) bool {
    if (expected.len != actual.len) return false;
    const Item = @TypeOf(expected.get(0));
    inline for (comptime std.meta.fieldNames(Item)) |name| {
        const column = @field(std.meta.FieldEnum(Item), name);
        for (expected.items(column), actual.items(column)) |a, b| {
            if (!std.meta.eql(a, b)) return false;
        }
    }
    return true;
}
