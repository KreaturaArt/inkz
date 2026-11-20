//! Size guards for the compiler's per-item types (F10), next to `src/core/sizes_test.zig`'s
//! for the runtime. Each is also asserted at compile time next to its type; these rows keep
//! the numbers in one place for the docs.

const std = @import("std");
const core = @import("core.zig");
const grammar = @import("grammar.zig");
const sema = @import("sema.zig");
const ast = @import("ast.zig");

/// The bytes one element of each of a struct's slices costs (the struct holds SoA slices).
fn slice_element_bytes(comptime T: type) comptime_int {
    var total: comptime_int = 0;
    for (@typeInfo(T).@"struct".field_types) |Field| {
        total += @sizeOf(@typeInfo(Field).pointer.child);
    }
    return total;
}

test "the parser's frame, checkpoint, diagnostic and token stay small" {
    try std.testing.expectEqual(20, @sizeOf(grammar.Machine.Checkpoint));
    try std.testing.expectEqual(36, @sizeOf(grammar.Machine.Frame));
    try std.testing.expectEqual(12, @sizeOf(core.Diagnostic));
    try std.testing.expectEqual(8, core.token_bytes);
    // A node is a tag byte and a word, as two arrays.
    try std.testing.expectEqual(5, @sizeOf(ast.Tag) + @sizeOf(u32));
}

test "a sema object costs 27 bytes across its arrays" {
    // kinds 1, flags 2, parents 4, nodes 4, children_first 4, children_count 4, one entry
    // in `children` 4 (each object but the root is one child) and indents 4.
    try std.testing.expectEqual(27, slice_element_bytes(sema.Tree));
}
