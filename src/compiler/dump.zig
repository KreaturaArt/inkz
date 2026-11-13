//! A syntax tree as an S-expression, for snapshot tests: `(tag child ...)`, a
//! leaf with a token as `tag"text"`, other leaves as their tag (and their number).

const std = @import("std");
const assert = std.debug.assert;
const ast = @import("ast.zig");
const grammar = @import("grammar.zig");
const lexical = @import("lexical.zig");

const stack_max = 4096;

const Entry = struct {
    node: ast.NodeIndex,
    /// The next child to print.
    next: u32,
};

/// Writes `parsed`'s tree to `out`; long lists have an item per line, indented.
pub fn write(parsed: *const grammar.Parsed, out: *std.Io.Writer) !void {
    assert(parsed.tree.root.to_int() < parsed.tree.tags.len);
    const tree = &parsed.tree;
    var stack: [stack_max]Entry = undefined;
    var depth: u32 = 1;
    stack[0] = .{ .node = tree.root, .next = 0 };
    try open(parsed, tree.root, out);
    while (depth > 0) {
        const entry = &stack[depth - 1];
        const children = child_count(tree, entry.node);
        if (entry.next == children) {
            try out.writeByte(')');
            depth -= 1;
            continue;
        }
        const child = child_at(tree, entry.node, entry.next);
        entry.next += 1;
        if (one_per_line(tree.tag(entry.node))) {
            try out.writeByte('\n');
            try out.splatByteAll(' ', 2 * depth);
        } else try out.writeByte(' ');
        if (ast.shape(tree.tag(child)) == .leaf) {
            try leaf(parsed, child, out);
        } else {
            assert(depth < stack_max);
            try open(parsed, child, out);
            stack[depth] = .{ .node = child, .next = 0 };
            depth += 1;
        }
    }
    try out.writeByte('\n');
}

/// Writes the diagnostics, one per line: `! line:column code detail`.
pub fn write_diagnostics(parsed: *const grammar.Parsed, out: *std.Io.Writer) !void {
    assert(parsed.tokens_count <= parsed.workspace.token_starts.len);
    assert(parsed.diagnostics_count <= parsed.workspace.diagnostics.len);
    for (parsed.diagnostics()) |diagnostic| {
        const position = lexical.line_and_column(parsed.source, diagnostic.offset);
        try out.print("! {d}:{d} {t}", .{ position.line, position.column, diagnostic.code });
        switch (diagnostic.code) {
            .expected => {
                const extra: u32 = diagnostic.extra;
                const expectation: grammar.Expectation = @fromBackingInt(extra);
                try out.print(" {t}", .{expectation});
            },
            .message => {
                const message: grammar.Message = @fromBackingInt(@intCast(diagnostic.extra));
                try out.print(" {t}", .{message});
            },
            else => {},
        }
        try out.writeByte('\n');
    }
}

/// Lists of statements and content get a line per item; short lists (paths, arguments,
/// parameters) stay on one line.
fn one_per_line(tag: ast.Tag) bool {
    assert(ast.shape(.story) == .list);
    assert(@backingInt(tag) < @typeInfo(ast.Tag).@"enum".field_names.len);
    return switch (tag) {
        .story, .statements, .content_list, .branches, .list_items, .string, .conditions => true,
        else => false,
    };
}

fn open(parsed: *const grammar.Parsed, node: ast.NodeIndex, out: *std.Io.Writer) !void {
    assert(node.to_int() < parsed.tree.tags.len);
    assert(ast.shape(parsed.tree.tag(node)) != .leaf);
    try out.writeByte('(');
    try out.writeAll(@tagName(parsed.tree.tag(node)));
}

fn child_count(tree: *const ast.Ast, node: ast.NodeIndex) u32 {
    assert(tree.tags.len == tree.data.len);
    assert(node.to_int() < tree.tags.len);
    return switch (ast.shape(tree.tag(node))) {
        .leaf => 0,
        .fixed => |count| count,
        .list => tree.list(node).count,
    };
}

fn child_at(tree: *const ast.Ast, node: ast.NodeIndex, position: u32) ast.NodeIndex {
    assert(node.to_int() < tree.tags.len);
    assert(position < child_count(tree, node));
    return switch (ast.shape(tree.tag(node))) {
        .leaf => unreachable,
        .fixed => tree.child(node, position),
        .list => .from_int(tree.list(node).first.to_int() + position),
    };
}

fn leaf(parsed: *const grammar.Parsed, node: ast.NodeIndex, out: *std.Io.Writer) !void {
    assert(node.to_int() < parsed.tree.data.len);
    const tag = parsed.tree.tag(node);
    const word = parsed.tree.data[node.to_int()];
    assert(ast.shape(tag) == .leaf);
    try out.writeAll(@tagName(tag));
    switch (tag) {
        .none, .missing, .count, .newline, .tag_end, .empty_divert => {},
        .header, .sequence_kind => try out.print(":{d}", .{word}),
        else => {
            assert(word < parsed.tokens_count);
            const workspace = &parsed.workspace;
            const text = parsed.source[workspace.token_starts[word]..workspace.token_ends[word]];
            try out.print("\"{s}\"", .{text});
        },
    }
}

/// Parses `source` and returns its dump (for tests); `diagnostics` gets the count.
pub fn dump_alloc(gpa: std.mem.Allocator, source: []const u8, diagnostics: *u32) ![]u8 {
    assert(source.len < std.math.maxInt(u32));
    var parsed = try grammar.parse(gpa, source, .{});
    defer parsed.deinit(gpa);
    diagnostics.* = parsed.diagnostics_count;
    var writer: std.Io.Writer.Allocating = .init(gpa);
    errdefer writer.deinit();
    try write(&parsed, &writer.writer);
    try write_diagnostics(&parsed, &writer.writer);
    return writer.toOwnedSlice();
}

test "a line of text" {
    // Content: a line is its text and a newline, flat in the statements.
    const gpa = std.testing.allocator;
    var diagnostics: u32 = 0;
    const text = try dump_alloc(gpa, "Hello, world.\n", &diagnostics);
    defer gpa.free(text);
    const expected = "(story\n  (statements\n    text\"Hello, world.\"\n    newline))\n";
    try std.testing.expectEqualStrings(expected, text);
    try std.testing.expectEqual(@as(u32, 0), diagnostics);
}
