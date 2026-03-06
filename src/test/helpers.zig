const std = @import("std");
const builtin = @import("builtin");
const Story = @import("../runtime/story.zig").Story;

/// Load a fixture file from the test/fixture/compiled/ directory.
/// Caller owns the returned memory (allocated with allocator).
pub fn loadFixture(allocator: std.mem.Allocator, comptime rel_path: []const u8) ![]const u8 {
    const path = "test/fixture/compiled/" ++ rel_path;
    var threaded: std.Io.Threaded = if (builtin.single_threaded)
        .init_single_threaded
    else
        .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024));
}

/// Drive a story through a choice sequence and return all concatenated output.
///
/// Loop: cont() → if choices remain, chooseChoiceIndex(choices[i]) → repeat.
/// Stops when the story can neither continue nor make a provided choice.
///
/// Caller owns the returned slice (allocated with `allocator`).
pub fn runStory(
    allocator: std.mem.Allocator,
    json: []const u8,
    choices: []const usize,
) ![]u8 {
    var s = try Story.initFromJson(allocator, json);
    defer s.deinit();

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    var choice_idx: usize = 0;
    while (true) {
        if (s.canContinue()) {
            const out = try s.cont();
            defer allocator.free(out);
            try output.appendSlice(allocator, out);
        } else if (s.currentChoices().len > 0 and choice_idx < choices.len) {
            try s.chooseChoiceIndex(choices[choice_idx]);
            choice_idx += 1;
        } else {
            break;
        }
    }

    return output.toOwnedSlice(allocator);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "loadFixture returns non-empty slice" {
    const data = try loadFixture(std.testing.allocator, "runtime/misc/hello_world.ink.json");
    defer std.testing.allocator.free(data);
    try std.testing.expect(data.len > 0);
}

test "runStory hello_world" {
    const alloc = std.testing.allocator;
    const json = try loadFixture(alloc, "runtime/misc/hello_world.ink.json");
    defer alloc.free(json);
    const out = try runStory(alloc, json, &.{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("Hello world\n", out);
}

test "runStory conditionals" {
    const alloc = std.testing.allocator;
    const json = try loadFixture(alloc, "runtime/conditions/conditionals.ink.json");
    defer alloc.free(json);
    const out = try runStory(alloc, json, &.{});
    defer alloc.free(out);
    // false branch → "true", 4>5 false → "4 is not greater than 5", etc.
    try std.testing.expect(std.mem.indexOf(u8, out, "true") != null);
}

test "runStory else_branches" {
    const alloc = std.testing.allocator;
    const json = try loadFixture(alloc, "runtime/conditions/else_branches.ink.json");
    defer alloc.free(json);
    const out = try runStory(alloc, json, &.{});
    defer alloc.free(out);
    // x initialised to some value; at least one branch fires
    try std.testing.expect(out.len > 0);
}

test "runStory logic_lines_with_newlines" {
    const alloc = std.testing.allocator;
    const json = try loadFixture(alloc, "runtime/logic/logic_lines_with_newlines.ink.json");
    defer alloc.free(json);
    const out = try runStory(alloc, json, &.{});
    defer alloc.free(out);
    // func() called twice; "text 2" appears twice
    try std.testing.expect(std.mem.count(u8, out, "text 2") >= 2);
}

test "runStory weave_gathers choice path one" {
    const alloc = std.testing.allocator;
    const json = try loadFixture(alloc, "runtime/weaves/weave_gathers.ink.json");
    defer alloc.free(json);
    // Path: choose "one" (0), then "two" (0) → "three\nsix\n"
    const out = try runStory(alloc, json, &.{ 0, 0 });
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "three") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "six") != null);
}

test "runStory weave_gathers choice path four" {
    const alloc = std.testing.allocator;
    const json = try loadFixture(alloc, "runtime/weaves/weave_gathers.ink.json");
    defer alloc.free(json);
    // Path: choose "four" (1) → "five\nsix\n"
    const out = try runStory(alloc, json, &.{1});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "five") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "six") != null);
}

test "runStory arithmetic" {
    const alloc = std.testing.allocator;
    const json = try loadFixture(alloc, "runtime/evaluation/arithmetic.ink.json");
    defer alloc.free(json);
    const out = try runStory(alloc, json, &.{});
    defer alloc.free(out);
    try std.testing.expect(out.len > 0);
}

test "runStory factorial_recursive" {
    const alloc = std.testing.allocator;
    const json = try loadFixture(alloc, "runtime/evaluation/factorial_recursive.ink.json");
    defer alloc.free(json);
    const out = try runStory(alloc, json, &.{});
    defer alloc.free(out);
    // 5! = 120
    try std.testing.expect(std.mem.indexOf(u8, out, "120") != null);
}

test "runStory basic_tunnel" {
    const alloc = std.testing.allocator;
    const json = try loadFixture(alloc, "runtime/diverts/basic_tunnel.ink.json");
    defer alloc.free(json);
    const out = try runStory(alloc, json, &.{});
    defer alloc.free(out);
    try std.testing.expect(out.len > 0);
}

test "runStory list_basic_operations" {
    const alloc = std.testing.allocator;
    const json = try loadFixture(alloc, "runtime/lists/list_basic_operations.ink.json");
    defer alloc.free(json);
    const out = try runStory(alloc, json, &.{});
    defer alloc.free(out);
    try std.testing.expect(out.len > 0);
}
