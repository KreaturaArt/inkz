/// Ink compiler entry point.
///
/// Takes Ink source text and produces a JSON string in the ink.json format
/// consumed by the runtime's Story.initFromJson.
const std = @import("std");
const parser = @import("parser.zig");
const codegen = @import("codegen.zig");
const serializer = @import("serializer.zig");

/// Compile Ink source to a JSON string.
/// The returned slice is allocated with `alloc` (caller owns it).
pub fn compile(alloc: std.mem.Allocator, source: []const u8) ![]u8 {
    // Parse and codegen inside an arena; only the JSON string escapes.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    const story = try parser.parse(aa, source);
    const root = try codegen.generate(aa, story);
    return serializer.serialize(alloc, root);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "Compiler compile: empty story compiles" {
    const alloc = std.testing.allocator;
    const json = try compile(alloc, "");
    defer alloc.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "inkVersion") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "g-0") != null);
}

test "Compiler compile: hello world compiles" {
    const alloc = std.testing.allocator;
    const json = try compile(alloc, "Hello world\n");
    defer alloc.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "Hello world") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "g-0") != null);
}
