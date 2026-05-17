/// Ink compiler entry point.
///
/// Takes Ink source text and produces either a JSON string (ink.json format) or a
/// ready-to-run Story directly, without a JSON round-trip.
const std = @import("std");
const parser = @import("parser.zig");
const codegen = @import("codegen.zig");
const serializer = @import("serializer.zig");
const c2r = @import("codegen_to_runtime.zig");
const Story = @import("../runtime/story.zig").Story;

/// Compile Ink source to a JSON string (ink.json format).
/// The returned slice is allocated with `alloc` (caller owns it).
/// Keeps full Inklecate compatibility; use compileToStory for in-process use.
pub fn compile(alloc: std.mem.Allocator, source: []const u8) ![]u8 {
    // Parse and codegen inside an arena; only the JSON string escapes.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    const parsed_story = try parser.parse(aa, source);
    const root = try codegen.generate(aa, parsed_story);
    return serializer.serializeWithListDefs(alloc, root, parsed_story.list_defs);
}

/// Compile Ink source directly to a Story, skipping JSON serialization/deserialization.
/// Equivalent to compile() + Story.initFromJson() but without the JSON round-trip overhead.
/// The returned Story must be freed with story.deinit().
pub fn compileToStory(alloc: std.mem.Allocator, source: []const u8) !Story {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const aa = arena.allocator();

    const parsed_story = try parser.parse(aa, source);
    const root = try codegen.generate(aa, parsed_story);
    const result = try c2r.convert(aa, root);
    const list_defs = try c2r.buildListDefs(aa, parsed_story.list_defs);
    return Story.initFromContainers(alloc, arena, result.containers, result.named_entries, list_defs);
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

fn runViaJson(alloc: std.mem.Allocator, src: []const u8) ![]u8 {
    const json = try compile(alloc, src);
    defer alloc.free(json);
    var s = try Story.initFromJson(alloc, json);
    defer s.deinit();
    return collectOutput(alloc, &s);
}

fn runDirect(alloc: std.mem.Allocator, src: []const u8) ![]u8 {
    var s = try compileToStory(alloc, src);
    defer s.deinit();
    return collectOutput(alloc, &s);
}

fn collectOutput(alloc: std.mem.Allocator, s: *Story) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    while (s.canContinue()) {
        const chunk = try s.cont();
        defer alloc.free(chunk);
        try out.appendSlice(alloc, chunk);
    }
    return out.toOwnedSlice(alloc);
}

test "compileToStory: hello world matches JSON path" {
    const alloc = std.testing.allocator;
    const src = "Hello world\n";
    const via_json = try runViaJson(alloc, src);
    defer alloc.free(via_json);
    const direct = try runDirect(alloc, src);
    defer alloc.free(direct);
    try std.testing.expectEqualStrings(via_json, direct);
}

test "compileToStory: arithmetic matches JSON path" {
    const alloc = std.testing.allocator;
    const src = "{ 2 * 3 }\n";
    const via_json = try runViaJson(alloc, src);
    defer alloc.free(via_json);
    const direct = try runDirect(alloc, src);
    defer alloc.free(direct);
    try std.testing.expectEqualStrings(via_json, direct);
}

test "compileToStory: knot divert matches JSON path" {
    const alloc = std.testing.allocator;
    const src =
        \\-> greeting
        \\=== greeting ===
        \\Hello from a knot!
        \\-> END
    ;
    const via_json = try runViaJson(alloc, src);
    defer alloc.free(via_json);
    const direct = try runDirect(alloc, src);
    defer alloc.free(direct);
    try std.testing.expectEqualStrings(via_json, direct);
}

test "compileToStory: VAR global variable matches JSON path" {
    const alloc = std.testing.allocator;
    const src =
        \\VAR score = 42
        \\Score: {score}
    ;
    const via_json = try runViaJson(alloc, src);
    defer alloc.free(via_json);
    const direct = try runDirect(alloc, src);
    defer alloc.free(direct);
    try std.testing.expectEqualStrings(via_json, direct);
}
