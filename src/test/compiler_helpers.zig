/// Test helper for the Ink compiler.
///
/// compileAndRun compiles Ink source to JSON, loads it in the runtime,
/// drives the story through a choice sequence, and returns the output.
const std = @import("std");
const Story = @import("../runtime/story.zig").Story;
const compiler = @import("../compiler/compiler.zig");

/// Compile `ink_source`, run the story through `choices`, and return all output.
/// Caller owns the returned slice.
pub fn compileAndRun(
    alloc: std.mem.Allocator,
    ink_source: []const u8,
    choices: []const usize,
) ![]u8 {
    const json = try compiler.compile(alloc, ink_source);
    defer alloc.free(json);

    var s = try Story.initFromJson(alloc, json);
    defer s.deinit();

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(alloc);

    var choice_idx: usize = 0;
    while (true) {
        if (s.canContinue()) {
            const out = try s.cont();
            defer alloc.free(out);
            try output.appendSlice(alloc, out);
        } else if (s.currentChoices().len > 0 and choice_idx < choices.len) {
            try s.chooseChoiceIndex(choices[choice_idx]);
            choice_idx += 1;
        } else {
            break;
        }
    }

    return output.toOwnedSlice(alloc);
}

/// Load an .ink file from test/fixture/original/, compile and run it.
/// Caller owns the returned slice.
pub fn compileFixtureAndRun(
    alloc: std.mem.Allocator,
    comptime rel_path: []const u8,
    choices: []const usize,
) ![]u8 {
    const path = "test/fixture/original/" ++ rel_path;
    const io = std.testing.io;

    const src = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(4 * 1024 * 1024));
    defer alloc.free(src);

    return compileAndRun(alloc, src, choices);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "Compiler e2e: empty story" {
    const alloc = std.testing.allocator;
    const out = try compileAndRun(alloc, "", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "Compiler e2e: hello world inline" {
    const alloc = std.testing.allocator;
    const out = try compileAndRun(alloc, "Hello world\n", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("Hello world\n", out);
}

test "Compiler e2e: text with END" {
    const alloc = std.testing.allocator;
    const out = try compileAndRun(alloc,
        \\hello
        \\-> END
        \\world
        \\-> END
    , &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("hello\n", out);
}

test "Compiler e2e: divert to knot then END" {
    const alloc = std.testing.allocator;
    const out = try compileAndRun(alloc,
        \\-> test
        \\== test ==
        \\hello
        \\-> END
        \\world
        \\-> END
    , &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("hello\n", out);
}

test "Compiler e2e: multi-knot story" {
    const alloc = std.testing.allocator;
    const out = try compileAndRun(alloc,
        \\-> firstKnot
        \\=== firstKnot
        \\Hello!
        \\-> anotherKnot
        \\=== anotherKnot
        \\World.
        \\-> END
    , &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("Hello!\nWorld.\n", out);
}

test "Compiler e2e: misc/hello_world.ink fixture" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/misc/hello_world.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("Hello world\n", out);
}

test "Compiler e2e: misc/empty.ink fixture" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/misc/empty.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "Compiler e2e: misc/end.ink fixture" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/misc/end.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("hello\n", out);
}

test "Compiler e2e: misc/end2.ink fixture" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/misc/end2.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("hello\n", out);
}

test "Compiler e2e: misc/end_of_content.ink fixture" {
    // The story has a knot "test" but no root-level divert to it.
    // Root flow is just the implicit g-0 done container → output is empty.
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/misc/end_of_content.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "Compiler e2e: misc/whitespace.ink fixture" {
    const alloc = std.testing.allocator;
    const out = try compileFixtureAndRun(alloc, "runtime/misc/whitespace.ink", &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("Hello!\nWorld.\n", out);
}
