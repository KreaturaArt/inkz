//! The transcript format. Tests describe host actions as the same `.actions` lines the C#
//! reference harness reads (`test/ground_truth/README.md`); `harness.zig` replays them on the
//! runtime and writes the result in the harness's exact format, so comparing the runtime
//! with ink is a text comparison. This file parses actions and typed values and escapes
//! text like the harness.

const std = @import("std");
const assert = std.debug.assert;
const HostValue = @import("../runtime/story.zig").HostValue;

/// `play` stops after this many turns, like the harness, so looping stories end.
pub const turns_max = 200;

pub const Kind = enum {
    seed,
    @"continue",
    continue_maximally,
    choices,
    choose,
    play,
    /// Like `play`, but each choice index comes from `new Random(seed)`.
    play_seeded,
    /// Records every global variable, sorted by name.
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
    /// Records the host events as `event:` lines.
    events,
};

/// One action: its kind and the rest of the line, trimmed.
pub const Action = struct {
    kind: Kind,
    argument: []const u8,
};

/// Parses one line of an `.actions` file; null for blank lines and comments.
pub fn parse_action(line_raw: []const u8) !?Action {
    const line = std.mem.trim(u8, line_raw, " \t\r");
    if (line.len == 0 or line[0] == '#') return null;
    const space = std.mem.indexOfScalar(u8, line, ' ');
    const name = if (space) |at| line[0..at] else line;
    const argument = if (space) |at| std.mem.trim(u8, line[at + 1 ..], " ") else "";
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
    return .{ .kind = kind, .argument = argument };
}

/// The typed values of an `evaluate` action, after the function name.
pub const Arguments = struct {
    values: [16]HostValue = undefined,
    count: u32 = 0,

    pub fn slice(arguments: *const Arguments) []const HostValue {
        return arguments.values[0..arguments.count];
    }
};

/// Parses `text` as typed values, one after another; strings are unescaped into `buffer`.
pub fn parse_typed_list(text_raw: []const u8, buffer: []u8, arguments: *Arguments) !void {
    var rest = std.mem.trim(u8, text_raw, " ");
    var used: usize = 0;
    while (rest.len > 0) {
        if (arguments.count == arguments.values.len) return error.BadActionArgument;
        const space = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.BadActionArgument;
        const after_type = std.mem.trimStart(u8, rest[space + 1 ..], " ");
        const value_end = if (std.mem.startsWith(u8, rest, "string"))
            try json_string_end(after_type)
        else
            std.mem.indexOfScalar(u8, after_type, ' ') orelse after_type.len;
        const consumed = rest.len - after_type.len + value_end;
        const value = try parse_typed(rest[0..consumed], buffer[used..]);
        if (value == .string) used += value.string.len;
        arguments.values[arguments.count] = value;
        arguments.count += 1;
        rest = std.mem.trimStart(u8, rest[consumed..], " ");
    }
}

/// The length of the JSON string literal at the start of `text`.
fn json_string_end(text: []const u8) !usize {
    if (text.len == 0 or text[0] != '"') return error.BadActionArgument;
    var position: usize = 1;
    while (position < text.len) : (position += 1) {
        if (text[position] == '\\') {
            position += 1;
        } else if (text[position] == '"') {
            return position + 1;
        }
    }
    return error.BadActionArgument;
}

/// A typed value as the harness reads one: `int 5`, `float 2.5`, `bool true` or
/// `string "text"` (JSON-escaped; unescaped into `buffer`).
pub fn parse_typed(text_raw: []const u8, buffer: []u8) !HostValue {
    const text = std.mem.trim(u8, text_raw, " ");
    const space = std.mem.indexOfScalar(u8, text, ' ') orelse return error.BadActionArgument;
    const kind = text[0..space];
    const rest = std.mem.trim(u8, text[space + 1 ..], " ");
    if (std.mem.eql(u8, kind, "int")) return .{ .integer = try std.fmt.parseInt(i32, rest, 10) };
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
        } else if (byte < 0x20) {
            try writer.print("\\u{x:0>4}", .{byte});
        } else {
            try writer.writeByte(byte);
        }
    }
    try writer.writeByte('"');
}

test "control bytes are escaped like the harness" {
    // Identical escaping for bytes below 0x20: escape a mix and compare.
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try write_json_string(&writer, "a\x01\x1fé");
    try std.testing.expectEqualStrings("\"a\\u0001\\u001fé\"", writer.buffered());
}

test "unknown actions are rejected" {
    // A typo in an .actions file fails loudly: parse a bad and a good line.
    try std.testing.expectError(error.UnknownAction, parse_action("contineu"));
    const choose = (try parse_action("  choose 3 ")).?;
    try std.testing.expectEqual(Kind.choose, choose.kind);
    try std.testing.expectEqualStrings("3", choose.argument);
    try std.testing.expectEqual(@as(?Action, null), try parse_action("   # note"));
    try std.testing.expectError(error.BadActionArgument, parse_action("choose"));
    try std.testing.expectError(error.BadActionArgument, parse_action("save now"));
}

test "typed values parse one after another" {
    // `evaluate` arguments, including a string with spaces and escapes: parse
    // a mixed list.
    var buffer: [4096]u8 = undefined;
    var arguments: Arguments = .{};
    try parse_typed_list("int 5 string \"a \\\"b\\\"\" bool true float 2.5", &buffer, &arguments);
    const values = arguments.slice();
    try std.testing.expectEqual(@as(usize, 4), values.len);
    try std.testing.expectEqual(@as(i32, 5), values[0].integer);
    try std.testing.expectEqualStrings("a \"b\"", values[1].string);
    try std.testing.expect(values[2].bool);
    try std.testing.expectEqual(@as(f32, 2.5), values[3].float);
}
