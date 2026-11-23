//! A syntax tree as an S-expression, for snapshot tests: `(tag child ...)`, a
//! leaf with a token as `tag"text"`, other leaves as their tag (and their number).

const std = @import("std");
const assert = std.debug.assert;
const ast = @import("ast.zig");
const grammar = @import("grammar.zig");
const lexical = @import("lexical.zig");

/// Writes `parsed`'s tree to `out`; long lists have an item per line, indented.
pub fn write(gpa: std.mem.Allocator, parsed: *const grammar.Parsed, out: *std.Io.Writer) !void {
    const tree = &parsed.tree;
    var nodes = tree.walk(gpa, tree.root);
    defer nodes.deinit();
    while (try nodes.next()) |step| {
        if (step.leave) {
            try out.writeByte(')');
            continue;
        }
        if (step.depth > 0) {
            if (one_per_line(tree.tag(step.parent))) {
                try out.writeByte('\n');
                try out.splatByteAll(' ', 2 * step.depth);
            } else try out.writeByte(' ');
        }
        if (ast.shape(tree.tag(step.node)) == .leaf) {
            try leaf(parsed, step.node, out);
        } else {
            try out.writeByte('(');
            try out.writeAll(@tagName(tree.tag(step.node)));
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
    return switch (tag) {
        .story, .statements, .content_list, .branches, .list_items, .string, .conditions => true,
        else => false,
    };
}

fn leaf(parsed: *const grammar.Parsed, node: ast.NodeIndex, out: *std.Io.Writer) !void {
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
    var parsed = try grammar.parse(gpa, source, .{});
    defer parsed.deinit(gpa);
    diagnostics.* = parsed.diagnostics_count;
    var writer: std.Io.Writer.Allocating = .init(gpa);
    errdefer writer.deinit();
    try write(gpa, &parsed, &writer.writer);
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
