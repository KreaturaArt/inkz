//! The cleaned-text cache (P10.1) through the story API: glue, function-end trimming,
//! string evaluation, the newline lookahead, a flow switch and a save loaded mid-play all
//! change the output stream behind the cache. Each line equals ink's (ink v1.2.1, checked
//! with the .NET harness), and in Debug every line is also compared with a full clean.

const std = @import("std");
const assert = std.debug.assert;
const compile = @import("../compiler/compile.zig");
const api = @import("../runtime/api.zig");

const source =
    \\VAR x = "y"
    \\Hello <>
    \\world.
    \\~ temp s = "{x} and {f()}"
    \\{s}.
    \\A {f()} B
    \\Line one
    \\<> joined.
    \\-> side_done
    \\== side ==
    \\Side line.
    \\-> DONE
    \\== side_done ==
    \\* [Go] -> next
    \\== function f ==
    \\  padded   
    \\~ return "z"
    \\== next ==
    \\In next.
    \\-> END
    \\
;

fn expect_line(story: *api.Story, expected: []const u8) !void {
    assert(expected.len > 0);
    assert(story.can_continue());
    try std.testing.expectEqualStrings(expected, (try story.cont()).get());
}

test "lines stay ink's through glue, functions, flows and a load" {
    // Goal: P10.1's invalidation in a real story. Method: play to the choice with a flow
    // switch in between, save before the third line, load it back and play on.
    const gpa = std.testing.allocator;
    var program = try compile.compile_source(gpa, source);
    defer program.deinit(gpa);
    var story: api.Story = undefined;
    try story.init(gpa, &program, .{});
    defer story.deinit(gpa);
    try expect_line(&story, "Hello world.\n");
    try expect_line(&story, "y and paddedz.\n");
    try story.switch_flow("side");
    try story.choose_path_string("side", .{});
    try expect_line(&story, "Side line.\n");
    try story.switch_to_default_flow();
    var saved: std.Io.Writer.Allocating = .init(gpa);
    defer saved.deinit();
    try story.to_json(&saved.writer);
    try expect_line(&story, "A paddedz B\n");
    try story.load_json(saved.written());
    try expect_line(&story, "A paddedz B\n");
    try expect_line(&story, "Line one joined.\n");
    try std.testing.expectEqual(@as(u32, 1), story.current_choices_count());
    try story.choose_choice_index(0);
    try expect_line(&story, "In next.\n");
    try std.testing.expect(!story.can_continue());
}
