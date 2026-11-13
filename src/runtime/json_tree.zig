//! A flat JSON tree for loading saves: the document is tokenized once
//! into a caller-provided node array, with no allocation and no recursion. Each node knows
//! where its subtree ends, so objects can be searched by key in any order (saves are
//! JSON-equivalent) and skipped in O(1).

const std = @import("std");
const assert = std.debug.assert;

pub const Kind = enum(u8) { object, array, string, number, true, false, null };

pub const Node = struct {
    /// Byte offset of the token in the document (for strings, just inside the quotes).
    start: u32,
    /// Byte length (for strings, the raw escaped length).
    length: u32,
    /// The index just past this node's subtree.
    next: u32,
    kind: Kind,
    /// For strings: whether the raw text has escapes.
    escaped: bool = false,
};

comptime {
    assert(@sizeOf(Node) == 16);
}

pub const Error = error{ InvalidJson, JsonTooLarge, JsonTooDeep };

pub const depth_max = 64;

pub const Tree = struct {
    text: []const u8,
    nodes: []Node,

    /// Tokenizes `text` into `storage`.
    pub fn parse(text: []const u8, storage: []Node) Error!Tree {
        assert(storage.len > 0);
        if (text.len >= std.math.maxInt(u32)) return error.JsonTooLarge;
        var parser: Parser = .{ .text = text, .nodes = storage };
        try parser.value_and_rest();
        const tree: Tree = .{ .text = text, .nodes = storage[0..parser.count] };
        assert(tree.nodes.len > 0 and tree.nodes[0].next == tree.nodes.len);
        return tree;
    }

    pub fn raw(tree: Tree, node: u32) []const u8 {
        assert(tree.nodes[node].start <= tree.text.len);
        const item = tree.nodes[node];
        return tree.text[item.start..][0..item.length];
    }

    /// The value of key `key` in object `object`, or null.
    pub fn get(tree: Tree, object: u32, key: []const u8) ?u32 {
        assert(tree.nodes[object].kind == .object);
        var members = tree.children(object);
        while (members.next()) |name| {
            const value = name + 1;
            assert(value < tree.nodes.len);
            if (tree.nodes[name].escaped) {
                if (tree.string_equals(name, key)) return value;
            } else if (std.mem.eql(u8, tree.raw(name), key)) return value;
            members.skip_value(value);
        }
        return null;
    }

    /// The children of an array, or the member names of an object (call `skip_value` with
    /// each name + 1 to move past the value).
    pub fn children(tree: Tree, parent: u32) Children {
        assert(parent < tree.nodes.len);
        assert(tree.nodes[parent].kind == .object or tree.nodes[parent].kind == .array);
        return .{ .tree = tree, .at = parent + 1, .end = tree.nodes[parent].next };
    }

    pub fn count(tree: Tree, parent: u32) u32 {
        assert(parent < tree.nodes.len);
        var walker = tree.children(parent);
        var total: u32 = 0;
        const is_object = tree.nodes[parent].kind == .object;
        while (walker.next()) |child| : (total += 1) {
            if (is_object) walker.skip_value(child + 1);
        }
        assert(total <= tree.nodes.len);
        return total;
    }

    /// The decoded length of string `node`.
    pub fn string_length(tree: Tree, node: u32) Error!u32 {
        assert(tree.nodes[node].kind == .string);
        if (!tree.nodes[node].escaped) return tree.nodes[node].length;
        var counter: std.Io.Writer.Discarding = .init(&.{});
        tree.decode(node, &counter.writer) catch return error.InvalidJson;
        return @intCast(counter.count);
    }

    /// Writes the decoded text of string `node`.
    pub fn decode(tree: Tree, node: u32, writer: *std.Io.Writer) !void {
        assert(tree.nodes[node].kind == .string);
        return tree.decode_from(node, 0, writer);
    }

    /// Writes the decoded text of string `node` after its first `skip` raw bytes (which
    /// must not be part of an escape, such as ink's `^`).
    pub fn decode_from(tree: Tree, node: u32, skip: u32, writer: *std.Io.Writer) !void {
        assert(tree.nodes[node].kind == .string);
        assert(skip <= tree.nodes[node].length);
        const text = tree.raw(node)[skip..];
        var position: usize = 0;
        while (position < text.len) {
            const character = text[position];
            if (character != '\\') {
                try writer.writeByte(character);
                position += 1;
                continue;
            }
            position += try decode_escape(text, position, writer);
        }
    }

    fn string_equals(tree: Tree, node: u32, expected: []const u8) bool {
        assert(expected.len < 256);
        var buffer: [256]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        tree.decode(node, &writer) catch return false;
        return std.mem.eql(u8, writer.buffered(), expected);
    }

    pub fn integer(tree: Tree, node: u32) Error!i32 {
        if (tree.nodes[node].kind != .number) return error.InvalidJson;
        const text = tree.raw(node);
        assert(text.len > 0);
        return std.fmt.parseInt(i32, text, 10) catch {
            // ink writes whole floats with `.0`; a number read where an int is expected must
            // be an int.
            return error.InvalidJson;
        };
    }

    pub fn is_float(tree: Tree, node: u32) bool {
        assert(tree.nodes[node].kind == .number);
        return std.mem.indexOfAny(u8, tree.raw(node), ".eE") != null;
    }

    pub fn float(tree: Tree, node: u32) Error!f32 {
        assert(tree.text.len > 0);
        if (tree.nodes[node].kind != .number) return error.InvalidJson;
        return std.fmt.parseFloat(f32, tree.raw(node)) catch error.InvalidJson;
    }

    pub fn boolean(tree: Tree, node: u32) Error!bool {
        assert(tree.text.len > 0);
        const kind = tree.nodes[node].kind;
        if (kind != .true and kind != .false) return error.InvalidJson;
        return kind == .true;
    }
};

pub const Children = struct {
    tree: Tree,
    at: u32,
    end: u32,

    pub fn next(walker: *Children) ?u32 {
        assert(walker.end <= walker.tree.nodes.len);
        assert(walker.at <= walker.end);
        if (walker.at == walker.end) return null;
        const node = walker.at;
        walker.at = walker.tree.nodes[node].next;
        return node;
    }

    pub fn skip_value(walker: *Children, value: u32) void {
        assert(walker.tree.nodes[value].next <= walker.end);
        assert(value < walker.end);
        walker.at = walker.tree.nodes[value].next;
    }
};

/// One `\` escape at `position`; returns the bytes it took.
fn decode_escape(text: []const u8, position: usize, writer: *std.Io.Writer) !usize {
    assert(position < text.len);
    assert(text[position] == '\\');
    if (position + 1 >= text.len) return error.InvalidJson;
    const simple: ?u8 = switch (text[position + 1]) {
        '"' => '"',
        '\\' => '\\',
        '/' => '/',
        'b' => 8,
        'f' => 12,
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        'u' => null,
        else => return error.InvalidJson,
    };
    if (simple) |byte| {
        try writer.writeByte(byte);
        return 2;
    }
    if (position + 6 > text.len) return error.InvalidJson;
    var code: u21 = std.fmt.parseInt(u16, text[position + 2 ..][0..4], 16) catch
        return error.InvalidJson;
    var used: usize = 6;
    if (code >= 0xD800 and code < 0xDC00) {
        // A surrogate pair.
        if (position + 12 > text.len or text[position + 6] != '\\' or text[position + 7] != 'u') {
            return error.InvalidJson;
        }
        const low = std.fmt.parseInt(u16, text[position + 8 ..][0..4], 16) catch
            return error.InvalidJson;
        if (low < 0xDC00 or low > 0xDFFF) return error.InvalidJson;
        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
        used = 12;
    }
    var bytes: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(code, &bytes) catch return error.InvalidJson;
    try writer.writeAll(bytes[0..length]);
    return used;
}

const Parser = struct {
    text: []const u8,
    nodes: []Node,
    count: u32 = 0,
    at: u32 = 0,

    fn skip_whitespace(parser: *Parser) void {
        assert(parser.at <= parser.text.len);
        assert(parser.count <= parser.nodes.len);
        while (parser.at < parser.text.len) : (parser.at += 1) {
            switch (parser.text[parser.at]) {
                ' ', '\t', '\n', '\r' => {},
                else => return,
            }
        }
    }

    fn add(parser: *Parser, node: Node) Error!u32 {
        assert(parser.count <= parser.nodes.len);
        assert(node.start <= parser.text.len);
        if (parser.count == parser.nodes.len) return error.JsonTooLarge;
        parser.nodes[parser.count] = node;
        parser.count += 1;
        return parser.count - 1;
    }

    /// The whole document: one value, then only whitespace. Containers are tracked on an
    /// explicit stack of open node indices.
    fn value_and_rest(parser: *Parser) Error!void {
        assert(parser.count == 0);
        assert(parser.at == 0);
        var open: [depth_max]u32 = undefined;
        var depth: u32 = 0;
        // Whether the next token in the open container must be a value (after `:` or `[`).
        var expect_value = true;
        while (true) {
            parser.skip_whitespace();
            if (parser.at == parser.text.len) return error.InvalidJson;
            const character = parser.text[parser.at];
            if (depth > 0 and !expect_value and (character == ']' or character == '}')) {
                depth -= 1;
                const closing = open[depth];
                const want: u8 = if (parser.nodes[closing].kind == .array) ']' else '}';
                if (character != want) return error.InvalidJson;
                parser.nodes[closing].next = parser.count;
                parser.at += 1;
                if (depth == 0) break;
                try parser.after_value(open[0..depth], &expect_value);
                continue;
            }
            try parser.scalar_or_open(&open, &depth, &expect_value);
            if (depth == 0) break;
        }
        parser.skip_whitespace();
        if (parser.at != parser.text.len) return error.InvalidJson;
    }

    fn scalar_or_open(
        parser: *Parser,
        open: *[depth_max]u32,
        depth: *u32,
        expect_value: *bool,
    ) Error!void {
        assert(depth.* <= depth_max);
        assert(parser.at < parser.text.len);
        const character = parser.text[parser.at];
        const inside_object = depth.* > 0 and parser.nodes[open[depth.* - 1]].kind == .object;
        if (inside_object and expect_value.* == false) return error.InvalidJson;
        if (character == '{' or character == '[') {
            if (depth.* == depth_max) return error.JsonTooDeep;
            const kind: Kind = if (character == '{') .object else .array;
            open[depth.*] = try parser.add(.{
                .start = parser.at,
                .length = 1,
                .next = 0,
                .kind = kind,
            });
            depth.* += 1;
            parser.at += 1;
            parser.skip_whitespace();
            const empty = parser.at < parser.text.len and
                parser.text[parser.at] == (if (kind == .object) @as(u8, '}') else ']');
            expect_value.* = !empty;
            if (kind == .object and !empty) try parser.member_name(expect_value);
            return;
        }
        const node = try parser.scalar();
        parser.nodes[node].next = node + 1;
        if (depth.* > 0) try parser.after_value(open[0..depth.*], expect_value);
    }

    /// A member name and its `:`.
    fn member_name(parser: *Parser, expect_value: *bool) Error!void {
        assert(parser.count > 0);
        assert(parser.at <= parser.text.len);
        parser.skip_whitespace();
        if (parser.at >= parser.text.len or parser.text[parser.at] != '"') return error.InvalidJson;
        const name = try parser.string();
        parser.nodes[name].next = name + 1;
        parser.skip_whitespace();
        if (parser.at >= parser.text.len or parser.text[parser.at] != ':') return error.InvalidJson;
        parser.at += 1;
        expect_value.* = true;
    }

    /// After a value inside a container: `,` (then a value, or a name and `:`) or the end.
    fn after_value(parser: *Parser, open: []const u32, expect_value: *bool) Error!void {
        assert(parser.count > 0);
        assert(open.len > 0);
        parser.skip_whitespace();
        if (parser.at >= parser.text.len) return error.InvalidJson;
        if (parser.text[parser.at] != ',') {
            expect_value.* = false;
            return;
        }
        parser.at += 1;
        expect_value.* = true;
        if (parser.nodes[open[open.len - 1]].kind == .object) try parser.member_name(expect_value);
    }

    fn scalar(parser: *Parser) Error!u32 {
        assert(parser.at < parser.text.len);
        assert(parser.count <= parser.nodes.len);
        const character = parser.text[parser.at];
        if (character == '"') return parser.string();
        const words = [_]struct { []const u8, Kind }{
            .{ "true", .true },
            .{ "false", .false },
            .{ "null", .null },
        };
        for (words) |word| {
            if (std.mem.startsWith(u8, parser.text[parser.at..], word[0])) {
                const node = try parser.add(.{
                    .start = parser.at,
                    .length = @intCast(word[0].len),
                    .next = 0,
                    .kind = word[1],
                });
                parser.at += @intCast(word[0].len);
                return node;
            }
        }
        const start = parser.at;
        while (parser.at < parser.text.len) : (parser.at += 1) {
            switch (parser.text[parser.at]) {
                '0'...'9', '-', '+', '.', 'e', 'E' => {},
                else => break,
            }
        }
        if (parser.at == start) return error.InvalidJson;
        return parser.add(.{
            .start = start,
            .length = parser.at - start,
            .next = 0,
            .kind = .number,
        });
    }

    fn string(parser: *Parser) Error!u32 {
        assert(parser.at < parser.text.len);
        assert(parser.text[parser.at] == '"');
        parser.at += 1;
        const start = parser.at;
        var escaped = false;
        while (parser.at < parser.text.len) : (parser.at += 1) {
            const character = parser.text[parser.at];
            if (character == '"') break;
            if (character == '\\') {
                escaped = true;
                parser.at += 1;
            } else if (character < 0x20) return error.InvalidJson;
        } else return error.InvalidJson;
        const node = try parser.add(.{
            .start = start,
            .length = parser.at - start,
            .next = 0,
            .kind = .string,
            .escaped = escaped,
        });
        parser.at += 1;
        return node;
    }
};

test "a save-shaped document parses into a searchable tree" {
    // Keys in any order, nested containers, escapes: parse and look up.
    var storage: [64]Node = undefined;
    const text =
        \\{"b": [1, 2.5, {"x": true}], "a": "line\nnext é", "c": {}, "d": null}
    ;
    const tree = try Tree.parse(text, &storage);
    const a = tree.get(0, "a").?;
    var buffer: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try tree.decode(a, &writer);
    try std.testing.expectEqualStrings("line\nnext \u{e9}", writer.buffered());
    const b = tree.get(0, "b").?;
    try std.testing.expectEqual(@as(u32, 3), tree.count(b));
    var items = tree.children(b);
    try std.testing.expectEqual(@as(i32, 1), try tree.integer(items.next().?));
    try std.testing.expect(tree.is_float(items.next().?));
    try std.testing.expect(try tree.boolean(tree.get(items.next().?, "x").?));
    try std.testing.expectEqual(@as(u32, 0), tree.count(tree.get(0, "c").?));
    try std.testing.expectEqual(Kind.null, tree.nodes[tree.get(0, "d").?].kind);
    try std.testing.expect(tree.get(0, "missing") == null);
}

test "malformed JSON is rejected" {
    // Negative space: truncations and stray tokens.
    var storage: [64]Node = undefined;
    const malformed = [_][]const u8{
        "{", "[1,]", "{\"a\" 1}", "{\"a\":1,}", "[1] x", "\"open", "{1:2}",
    };
    for (malformed) |text| {
        try std.testing.expectError(error.InvalidJson, Tree.parse(text, &storage));
    }
    var tiny: [2]Node = undefined;
    try std.testing.expectError(error.JsonTooLarge, Tree.parse("[1, 2, 3]", &tiny));
}
