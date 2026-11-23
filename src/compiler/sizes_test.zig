//! Size guards for the compiler's per-item types (F10), next to `src/core/sizes_test.zig`'s
//! for the runtime. Each is also asserted at compile time next to its type; these rows keep
//! the numbers in one place for the docs.

const std = @import("std");
const core = @import("core.zig");
const grammar = @import("grammar.zig");
const sema = @import("sema.zig");
const ast = @import("ast.zig");

test "the parser's frame, checkpoint, diagnostic and token stay small" {
    try std.testing.expectEqual(20, @sizeOf(grammar.Machine.Checkpoint));
    try std.testing.expectEqual(36, @sizeOf(grammar.Machine.Frame));
    try std.testing.expectEqual(12, @sizeOf(core.Diagnostic));
    try std.testing.expectEqual(8, core.token_bytes);
    // A node is a tag byte and a word, as two arrays.
    try std.testing.expectEqual(5, @sizeOf(ast.Tag) + @sizeOf(u32));
}

test "a sema object costs 23 bytes across its arrays" {
    // kind 1, flags 2, parent 4, node 4, children_first 4, children_count 4, and one entry
    // in `children` 4 (each object but the root is one child).
    comptime var bytes: usize = @sizeOf(sema.ObjectIndex);
    inline for (@typeInfo(sema.Object).@"struct".field_types) |Field| bytes += @sizeOf(Field);
    try std.testing.expectEqual(23, bytes);
}
