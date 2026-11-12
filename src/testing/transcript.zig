//! The engine-neutral test layer (plan P0.11). Tests describe host actions once, as the same
//! `.actions` lines the C# reference harness reads (`test/ground_truth/README.md`), and replay
//! them against any engine. The result is a transcript in the harness's exact format, so
//! comparing an engine with ink is a text comparison.
//!
//! An engine is any type with:
//!   `tags_per_line: bool` (a declaration), `can_continue() bool`, `continue_line() !Line`,
//!   `choices_count() u32`, `choice(u32) Choice`, `choose(u32) !void` and `seed(i32) void`.
//! The other actions need an optional method of the same name as the action (`choose_path`,
//! `visit_count`, `switch_flow`, ...; see `apply_optional`). When an engine lacks one, the
//! transcript records `unsupported: <action>` and stops, so gaps show up in comparisons.
//! An engine error is recorded as `exception: "<name>"` and stops the transcript too, like an
//! ink exception in the harness; an engine with `exception_message() ?[]const u8` gives ink's
//! message instead. An engine with `write_messages(writer)` writes its host events, errors
//! and warnings after each action, like the harness's FlushMessages. Slices returned by an
//! engine are valid until its next mutating call.

const std = @import("std");
const assert = std.debug.assert;
const DotnetRandom = @import("../core/dotnet_random.zig").DotnetRandom;

/// `play` stops after this many turns, like the harness, so looping stories end.
pub const turns_max = 200;

pub const Kind = enum {
    seed,
    @"continue",
    continue_maximally,
    choices,
    choose,
    play,
    /// Like `play`, but each choice index comes from `new Random(seed)` (P0.3 transcripts).
    play_seeded,
    /// Records every global variable, sorted by name (P0.3 transcripts).
    globals,
    choose_path,
    evaluate,
    get,
    set,
    observe,
    bind,
    unbind,
    fallbacks,
    save,
    load,
    load_fresh,
    current_text,
    reset,
    switch_flow,
    remove_flow,
    default_flow,
    visit_count,
    tags_at,
    global_tags,
};

/// One action: its kind and the rest of the line, trimmed.
pub const Action = struct {
    kind: Kind,
    argument: []const u8,
};

/// A host-visible ink value, rendered like the harness renders C# values: `int 5`,
/// `float 2.5`, `bool true`, `string "a"`, `list "A.x, B.y"`, or `null`.
pub const Value = union(enum) {
    null,
    int: i64,
    float: f64,
    /// A float already formatted as .NET formats it (the new engine's f32).
    float_text: []const u8,
    bool: bool,
    string: []const u8,
    list: []const u8,
    other: []const u8,
};

pub fn write_value(writer: *std.Io.Writer, value: Value) !void {
    if (value == .string) assert(value.string.len < 1024 * 1024);
    if (value == .list) assert(value.list.len < 1024 * 1024);
    switch (value) {
        .null => try writer.writeAll("null"),
        .int => |number| try writer.print("int {d}", .{number}),
        .float => |number| try writer.print("float {d}", .{number}),
        .float_text => |text| try writer.print("float {s}", .{text}),
        .bool => |flag| try writer.writeAll(if (flag) "bool true" else "bool false"),
        .string => |text| {
            try writer.writeAll("string ");
            try write_json_string(writer, text);
        },
        inline .list, .other => |text, tag| {
            try writer.writeAll(@tagName(tag) ++ " ");
            try write_json_string(writer, text);
        },
    }
}

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
    const kind = std.meta.stringToEnum(Kind, name) orelse return error.UnknownAction;
    const needs_argument = switch (kind) {
        .seed, .choose, .choose_path, .evaluate, .get, .set, .observe, .bind, .unbind => true,
        .play_seeded => true,
        .fallbacks, .switch_flow, .remove_flow, .visit_count, .tags_at => true,
        else => false,
    };
    if (needs_argument != (argument.len > 0)) return error.BadActionArgument;
    if (kind == .seed) _ = try std.fmt.parseInt(i32, argument, 10);
    if (kind == .choose) _ = try std.fmt.parseInt(u32, argument, 10);
    if (kind == .play_seeded) _ = try std.fmt.parseInt(i32, argument, 10);
    assert(needs_argument == (argument.len > 0));
    return .{ .kind = kind, .argument = argument };
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
        const outcome = try apply(engine, action, writer);
        applied += 1;
        if (outcome == .stop) break;
    }
    assert(applied <= actions.len);
}

const Outcome = enum { next, stop };

fn apply(engine: anytype, action: Action, writer: *std.Io.Writer) !Outcome {
    comptime assert(@typeInfo(@TypeOf(engine)) == .pointer);
    comptime assert(@hasDecl(@typeInfo(@TypeOf(engine)).pointer.child, "tags_per_line"));
    const Engine = @typeInfo(@TypeOf(engine)).pointer.child;
    apply_required(engine, action, writer) catch |err| switch (err) {
        error.WriteFailed, error.OutOfMemory => |fatal| return fatal,
        error.Unsupported => {
            try writer.print("unsupported: {t}\n", .{action.kind});
            return .stop;
        },
        else => {
            if (@hasDecl(Engine, "write_messages")) try engine.write_messages(writer);
            try writer.writeAll("exception: ");
            var message: []const u8 = @errorName(err);
            if (@hasDecl(Engine, "exception_message")) {
                if (engine.exception_message()) |text| message = text;
            }
            try write_json_string(writer, message);
            try writer.writeByte('\n');
            return .stop;
        },
    };
    if (@hasDecl(Engine, "write_messages")) try engine.write_messages(writer);
    return .next;
}

fn apply_required(engine: anytype, action: Action, writer: *std.Io.Writer) anyerror!void {
    assert(action.argument.len < 4096);
    switch (action.kind) {
        .seed => engine.seed(std.fmt.parseInt(i32, action.argument, 10) catch unreachable),
        .@"continue" => try continue_once(engine, writer),
        .continue_maximally => try continue_maximally(engine, writer),
        .choices => try write_choices(engine, writer),
        .choose => try engine.choose(std.fmt.parseInt(u32, action.argument, 10) catch unreachable),
        .play => try play(engine, writer, null),
        .play_seeded => {
            const seed = std.fmt.parseInt(i32, action.argument, 10) catch unreachable;
            var random = DotnetRandom.init(seed);
            try play(engine, writer, &random);
        },
        else => try apply_optional(engine, action, writer),
    }
    assert(action.kind != .seed or action.argument.len > 0);
}

/// Actions that need an optional engine capability, named like the action.
fn apply_optional(engine: anytype, action: Action, writer: *std.Io.Writer) anyerror!void {
    const Engine = @typeInfo(@TypeOf(engine)).pointer.child;
    assert(action.argument.len < 4096);
    switch (action.kind) {
        inline .choose_path,
        .switch_flow,
        .remove_flow,
        .default_flow,
        .reset,
        .bind,
        .unbind,
        .fallbacks,
        => |kind| {
            if (!@hasDecl(Engine, @tagName(kind))) return error.Unsupported;
            try @field(Engine, @tagName(kind))(engine, action.argument);
        },
        .save => {
            if (!@hasDecl(Engine, "save")) return error.Unsupported;
            try writer.print("save: {s}\n", .{try engine.save()});
        },
        inline .load, .load_fresh => |kind| {
            if (!@hasDecl(Engine, @tagName(kind))) return error.Unsupported;
            try @field(Engine, @tagName(kind))(engine);
        },
        .visit_count => {
            if (!@hasDecl(Engine, "visit_count")) return error.Unsupported;
            try writer.print("visit_count: {d}\n", .{try engine.visit_count(action.argument)});
        },
        .set => {
            if (!@hasDecl(Engine, "set")) return error.Unsupported;
            const space = std.mem.indexOfScalar(u8, action.argument, ' ') orelse
                return error.BadActionArgument;
            var buffer: [4096]u8 = undefined;
            const value = try parse_typed(action.argument[space + 1 ..], &buffer);
            try engine.set(action.argument[0..space], value);
        },
        .get => {
            if (!@hasDecl(Engine, "get")) return error.Unsupported;
            try writer.writeAll("value: ");
            try write_value(writer, try engine.get(action.argument));
            try writer.writeByte('\n');
        },
        .globals => {
            if (!@hasDecl(Engine, "global_names")) return error.Unsupported;
            for (try engine.global_names()) |name| {
                try writer.print("global: {s} = ", .{name});
                try write_value(writer, try engine.get(name));
                try writer.writeByte('\n');
            }
        },
        .tags_at => {
            if (!@hasDecl(Engine, "tags_at")) return error.Unsupported;
            try writer.writeAll("tags: ");
            try write_tags(writer, try engine.tags_at(action.argument));
            try writer.writeByte('\n');
        },
        .global_tags => {
            if (!@hasDecl(Engine, "global_tags")) return error.Unsupported;
            try writer.writeAll("tags: ");
            try write_tags(writer, try engine.global_tags());
            try writer.writeByte('\n');
        },
        else => return error.Unsupported,
    }
    assert(action.kind != .play);
}

fn write_tags(writer: *std.Io.Writer, tags: []const []const u8) !void {
    assert(tags.len < 1024);
    for (tags) |tag| assert(tag.len < 4096);
    if (tags.len == 0) return writer.writeAll("[]");
    try write_json_list(writer, tags);
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
    // The harness flushes host events and messages after each line.
    const Engine = @typeInfo(@TypeOf(engine)).pointer.child;
    if (@hasDecl(Engine, "write_messages")) try engine.write_messages(writer);
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

/// Continues maximally and makes a choice until the story ends or `turns_max`: the first
/// choice, or one picked by `random` (`Next() % count`) when it is given.
fn play(engine: anytype, writer: *std.Io.Writer, random: ?*DotnetRandom) !void {
    comptime assert(turns_max > 0);
    var turn: u32 = 0;
    while (turn < turns_max) : (turn += 1) {
        try continue_maximally(engine, writer);
        try write_choices(engine, writer);
        if (engine.choices_count() == 0) {
            try writer.writeAll("end\n");
            return;
        }
        const count = engine.choices_count();
        const index = if (random) |generator| pick(generator, count) else 0;
        assert(index < count);
        try writer.print("choose: {d}\n", .{index});
        try engine.choose(index);
    }
    assert(turn == turns_max);
    try writer.writeAll("turns_max reached\n");
}

/// `Next() % count`, as a host would pick a choice with .NET's Random.
fn pick(random: *DotnetRandom, count: u32) u32 {
    assert(count > 0);
    const index: u32 = @intCast(@mod(random.next(), @as(i32, @intCast(count))));
    assert(index < count);
    return index;
}

/// A typed value as the harness reads one: `int 5`, `float 2.5`, `bool true` or
/// `string "text"` (JSON-escaped; unescaped into `buffer`).
pub fn parse_typed(text_raw: []const u8, buffer: []u8) !Value {
    const text = std.mem.trim(u8, text_raw, " ");
    const space = std.mem.indexOfScalar(u8, text, ' ') orelse return error.BadActionArgument;
    const kind = text[0..space];
    const rest = std.mem.trim(u8, text[space + 1 ..], " ");
    assert(rest.len <= text.len);
    if (std.mem.eql(u8, kind, "int")) return .{ .int = try std.fmt.parseInt(i32, rest, 10) };
    if (std.mem.eql(u8, kind, "float")) return .{ .float = try std.fmt.parseFloat(f32, rest) };
    if (std.mem.eql(u8, kind, "bool")) return .{ .bool = std.mem.eql(u8, rest, "true") };
    if (!std.mem.eql(u8, kind, "string")) return error.BadActionArgument;
    var fixed: std.heap.FixedBufferAllocator = .init(buffer);
    const unescaped = std.json.parseFromSliceLeaky([]const u8, fixed.allocator(), rest, .{}) catch
        return error.BadActionArgument;
    return .{ .string = unescaped };
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
    // Goal: byte-for-byte the format of tools/ink_harness/Transcript.cs, and stopping at an
    // unsupported action. Method: replay against a scripted engine without visit_count.
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
        \\visit_count knot
        \\continue
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
        \\> visit_count knot
        \\unsupported: visit_count
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
    const choose = (try parse_action("  choose 3 ")).?;
    try std.testing.expectEqual(Kind.choose, choose.kind);
    try std.testing.expectEqualStrings("3", choose.argument);
    try std.testing.expectEqual(@as(?Action, null), try parse_action("   # note"));
    try std.testing.expectError(error.BadActionArgument, parse_action("choose"));
    try std.testing.expectError(error.BadActionArgument, parse_action("save now"));
}
