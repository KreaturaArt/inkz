//! The engine-neutral test layer (plan P0.11). Tests describe host actions once, as the same
//! `.actions` lines the C# reference harness reads (`test/ground_truth/README.md`), and replay
//! them against any engine. The result is a transcript in the harness's exact format, so
//! comparing an engine with ink is a text comparison.
//!
//! An engine is any type with:
//!   `tags_per_line: bool` (a declaration), `can_continue() bool`, `continue_line() !Line`,
//!   `choices_count() u32`, `choice(u32) Choice`, `choose(u32) !void` and `seed(i32) void`.
//! Slices returned by an engine are valid until its next mutating call.

const std = @import("std");
const assert = std.debug.assert;

/// `play` stops after this many turns, like the harness, so looping stories end.
pub const turns_max = 200;

pub const Action = union(enum) {
    seed: i32,
    @"continue",
    continue_maximally,
    choices,
    choose: u32,
    play,
};

pub const Line = struct {
    text: []const u8,
    tags: []const []const u8,
};

pub const Choice = struct {
    text: []const u8,
    tags: []const []const u8,
};

/// Parses one line of an `.actions` file; null for blank lines and comments.
pub fn parse_action(line_raw: []const u8) !?Action {
    const line = std.mem.trim(u8, line_raw, " \t\r");
    if (line.len == 0 or line[0] == '#') return null;
    const space = std.mem.indexOfScalar(u8, line, ' ');
    const name = if (space) |at| line[0..at] else line;
    const argument = if (space) |at| std.mem.trim(u8, line[at + 1 ..], " ") else "";
    assert(name.len > 0);
    const action: Action = if (std.mem.eql(u8, name, "seed"))
        .{ .seed = try std.fmt.parseInt(i32, argument, 10) }
    else if (std.mem.eql(u8, name, "continue"))
        .@"continue"
    else if (std.mem.eql(u8, name, "continue_maximally"))
        .continue_maximally
    else if (std.mem.eql(u8, name, "choices"))
        .choices
    else if (std.mem.eql(u8, name, "choose"))
        .{ .choose = try std.fmt.parseInt(u32, argument, 10) }
    else if (std.mem.eql(u8, name, "play"))
        .play
    else
        return error.UnknownAction;
    if (action == .seed or action == .choose) assert(argument.len > 0);
    return action;
}

/// Replays every action in `actions` against `engine`, writing the transcript (without the
/// harness's provenance header) to `writer`.
pub fn replay(engine: anytype, actions: []const u8, writer: *std.Io.Writer) !void {
    assert(actions.len < 1024 * 1024);
    var lines = std.mem.splitScalar(u8, actions, '\n');
    var applied: u32 = 0;
    while (lines.next()) |line| {
        const action = try parse_action(line) orelse continue;
        try writer.print("> {s}\n", .{std.mem.trim(u8, line, " \t\r")});
        try apply(engine, action, writer);
        applied += 1;
    }
    assert(applied <= actions.len);
}

fn apply(engine: anytype, action: Action, writer: *std.Io.Writer) !void {
    comptime assert(@typeInfo(@TypeOf(engine)) == .pointer);
    comptime assert(@hasDecl(@typeInfo(@TypeOf(engine)).pointer.child, "tags_per_line"));
    switch (action) {
        .seed => |seed| engine.seed(seed),
        .@"continue" => try continue_once(engine, writer),
        .continue_maximally => try continue_maximally(engine, writer),
        .choices => try write_choices(engine, writer),
        .choose => |index| try engine.choose(index),
        .play => try play(engine, writer),
    }
}

fn continue_once(engine: anytype, writer: *std.Io.Writer) !void {
    comptime assert(@typeInfo(@TypeOf(engine)) == .pointer);
    if (!engine.can_continue()) {
        try writer.writeAll("can_continue: false\n");
        return;
    }
    const line = try engine.continue_line();
    try writer.writeAll("text: ");
    try write_json_string(writer, line.text);
    try writer.writeByte('\n');
    if (line.tags.len > 0) {
        try writer.writeAll("tags: ");
        try write_json_list(writer, line.tags);
        try writer.writeByte('\n');
    }
    assert(line.text.len < 1024 * 1024);
}

fn continue_maximally(engine: anytype, writer: *std.Io.Writer) !void {
    var lines: u32 = 0;
    const lines_max = 100_000;
    while (engine.can_continue()) : (lines += 1) {
        if (lines == lines_max) return error.ContinueLimit;
        try continue_once(engine, writer);
    }
    assert(!engine.can_continue());
    assert(lines <= lines_max);
}

fn write_choices(engine: anytype, writer: *std.Io.Writer) !void {
    const count = engine.choices_count();
    assert(count < 1024);
    try writer.print("choices: {d}\n", .{count});
    for (0..count) |index| {
        const choice = engine.choice(@intCast(index));
        try writer.print("  {d}: ", .{index});
        try write_json_string(writer, choice.text);
        if (choice.tags.len > 0) {
            try writer.writeAll(" tags ");
            try write_json_list(writer, choice.tags);
        }
        try writer.writeByte('\n');
    }
    assert(engine.choices_count() == count);
}

/// Continues maximally and picks the first choice until the story ends or `turns_max`.
fn play(engine: anytype, writer: *std.Io.Writer) !void {
    comptime assert(turns_max > 0);
    var turn: u32 = 0;
    while (turn < turns_max) : (turn += 1) {
        try continue_maximally(engine, writer);
        try write_choices(engine, writer);
        if (engine.choices_count() == 0) {
            try writer.writeAll("end\n");
            return;
        }
        try writer.writeAll("choose: 0\n");
        try engine.choose(0);
    }
    assert(turn == turns_max);
    try writer.writeAll("turns_max reached\n");
}

/// Escapes like the harness: `"`, `\`, `\n`, `\r`, `\t`, other control bytes as `\u00xx`,
/// everything else (including UTF-8) as is.
pub fn write_json_string(writer: *std.Io.Writer, text: []const u8) !void {
    assert(text.len < 1024 * 1024);
    var written: usize = 2;
    try writer.writeByte('"');
    for (text) |byte| {
        const escape: ?[]const u8 = switch (byte) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            else => null,
        };
        if (escape) |sequence| {
            try writer.writeAll(sequence);
            written += sequence.len;
        } else if (byte < 0x20) {
            try writer.print("\\u{x:0>4}", .{byte});
            written += 6;
        } else {
            try writer.writeByte(byte);
            written += 1;
        }
    }
    try writer.writeByte('"');
    // Escaping never shortens text.
    assert(written >= text.len + 2);
}

fn write_json_list(writer: *std.Io.Writer, items: []const []const u8) !void {
    assert(items.len > 0);
    try writer.writeByte('[');
    for (items, 0..) |item, index| {
        if (index > 0) try writer.writeAll(", ");
        try write_json_string(writer, item);
    }
    try writer.writeByte(']');
    assert(items.len < 1024);
}

/// A scripted engine for testing the layer itself: two lines, then two choices, then one more
/// line after either choice.
const FakeEngine = struct {
    pub const tags_per_line = true;
    lines_left: u32 = 2,
    chosen: bool = false,
    seed_value: i32 = 0,

    fn can_continue(engine: *const FakeEngine) bool {
        assert(engine.lines_left <= 2);
        const result = engine.lines_left > 0;
        assert(result or engine.lines_left == 0);
        return result;
    }

    fn continue_line(engine: *FakeEngine) !Line {
        assert(engine.lines_left > 0);
        engine.lines_left -= 1;
        if (engine.chosen) return .{ .text = "After.\n", .tags = &.{} };
        if (engine.lines_left == 1) return .{ .text = "Say \"hi\"\t\n", .tags = &.{"greeting"} };
        assert(engine.lines_left == 0);
        return .{ .text = "Pick one.\n", .tags = &.{} };
    }

    fn choices_count(engine: *const FakeEngine) u32 {
        assert(engine.lines_left <= 2);
        const count: u32 = if (engine.chosen or engine.lines_left > 0) 0 else 2;
        assert(count <= 2);
        return count;
    }

    fn choice(engine: *const FakeEngine, index: u32) Choice {
        assert(index < engine.choices_count());
        assert(!engine.chosen);
        if (index == 0) return .{ .text = "Left", .tags = &.{} };
        return .{ .text = "Right", .tags = &.{"r"} };
    }

    fn choose(engine: *FakeEngine, index: u32) !void {
        assert(index < engine.choices_count());
        engine.chosen = true;
        engine.lines_left = 1;
        assert(engine.can_continue());
    }

    fn seed(engine: *FakeEngine, value: i32) void {
        engine.seed_value = value;
        assert(engine.seed_value == value);
        assert(engine.lines_left <= 2);
    }
};

fn replay_to_string(gpa: std.mem.Allocator, engine: anytype, actions: []const u8) ![]u8 {
    assert(actions.len > 0);
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    try replay(engine, actions, &output.writer);
    const text = try output.toOwnedSlice();
    assert(text.len > 0);
    return text;
}

test "replay renders the harness transcript format" {
    // Goal: byte-for-byte the format of tools/ink_harness/Transcript.cs. Method: replay every
    // action kind against a scripted engine and compare with the expected text.
    const gpa = std.testing.allocator;
    var engine: FakeEngine = .{};
    const actions =
        \\# a comment
        \\seed 7
        \\continue
        \\
        \\continue
        \\continue
        \\choices
        \\play
        \\
    ;
    const text = try replay_to_string(gpa, &engine, actions);
    defer gpa.free(text);
    const expected =
        \\> seed 7
        \\> continue
        \\text: "Say \"hi\"\t\n"
        \\tags: ["greeting"]
        \\> continue
        \\text: "Pick one.\n"
        \\> continue
        \\can_continue: false
        \\> choices
        \\choices: 2
        \\  0: "Left"
        \\  1: "Right" tags ["r"]
        \\> play
        \\choices: 2
        \\  0: "Left"
        \\  1: "Right" tags ["r"]
        \\choose: 0
        \\text: "After.\n"
        \\choices: 0
        \\end
        \\
    ;
    try std.testing.expectEqualStrings(expected, text);
    try std.testing.expectEqual(@as(i32, 7), engine.seed_value);
}

test "control bytes are escaped like the harness" {
    // Goal: identical escaping for bytes below 0x20. Method: escape a mix and compare.
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try write_json_string(&writer, "a\x01\x1fé");
    try std.testing.expectEqualStrings("\"a\\u0001\\u001fé\"", writer.buffered());
}

test "unknown actions are rejected" {
    // Goal: a typo in an .actions file fails loudly. Method: parse a bad and a good line.
    try std.testing.expectError(error.UnknownAction, parse_action("contineu"));
    try std.testing.expectEqual(Action{ .choose = 3 }, (try parse_action("  choose 3 ")).?);
    try std.testing.expectEqual(@as(?Action, null), try parse_action("   # note"));
}
