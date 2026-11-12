//! `zig build doctest` (plan P9.3): compiles every ```zig block of the given Markdown files
//! against the library, imported as "inkz" (src/root.zig). `zig build test` runs it too.
//!
//! Usage: `doctest <output directory> <doc.md>...`. It writes one Zig file per block,
//! `<doc>_<line>.zig`, and `root.zig`, which has one test per block, named `<doc>.md:<line>`
//! after the line of the opening fence. The build compiles and runs `root.zig`.
//!
//! The convention, decided per block:
//! - A *file* block has a line that starts at column 0 with `pub `, `fn `, `test "` or
//!   `const <name> = @import(`. It is compiled as a file of its own, unchanged: it imports
//!   what it uses. Its declarations are referenced, so they are compiled, and its tests run.
//! - Every other block is a *body*. It is wrapped in
//!   `pub fn sample(gpa: std.mem.Allocator, io: std.Io, story: *inkz.Story) !void`, with
//!   `std` and `inkz` imported, so a snippet can use an allocator, an `Io` and a story without
//!   making them. A body that declares its own story (`var story` or `const story`) gets no
//!   `story` parameter. Bodies are compiled, not run.
//! - Anything that is not Zig for this library (shell, ink, pseudo-code, other APIs) goes in a
//!   block with another fence: ```sh, ```ink, ```text.
//!
//! A fence may be indented (inside a list item); the block's lines lose that indentation.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub const blocks_max = 1024;
const doc_bytes_max = 4 * 1024 * 1024;

pub const Kind = enum { file, body };

pub const Block = struct {
    /// The 1-based line of the opening fence.
    line: u32,
    /// The block's text, without its fences and their indentation.
    text: []const u8,
};

pub const Error = error{ UnterminatedBlock, TooManyBlocks } || Allocator.Error;

/// Every ```zig block of `markdown`, in order.
pub fn extract(arena: Allocator, markdown: []const u8) Error![]Block {
    assert(markdown.len <= doc_bytes_max);
    var blocks: std.ArrayList(Block) = .empty;
    var lines = std.mem.splitScalar(u8, markdown, '\n');
    var line_number: u32 = 0;
    while (lines.next()) |line| {
        line_number += 1;
        const indent = fence_indent(line, "zig") orelse continue;
        if (blocks.items.len == blocks_max) return error.TooManyBlocks;
        const opening = line_number;
        var text: std.ArrayList(u8) = .empty;
        const closed = while (lines.next()) |inner| {
            line_number += 1;
            if (fence_indent(inner, "") != null) break true;
            try text.appendSlice(arena, dedent(inner, indent));
            try text.append(arena, '\n');
        } else false;
        if (!closed) return error.UnterminatedBlock;
        try blocks.append(arena, .{ .line = opening, .text = text.items });
    }
    assert(blocks.items.len <= blocks_max);
    return blocks.items;
}

/// The indentation of a fence line whose info string is `language`, or null if `line` is
/// not one. An empty `language` matches only a bare fence (a closing one).
fn fence_indent(line: []const u8, language: []const u8) ?u32 {
    assert(line.len <= doc_bytes_max);
    assert(language.len < 16);
    const trimmed = std.mem.trimStart(u8, line, " ");
    if (!std.mem.startsWith(u8, trimmed, "```")) return null;
    const info = std.mem.trim(u8, trimmed[3..], " \t\r");
    if (!std.mem.eql(u8, info, language)) return null;
    return @intCast(line.len - trimmed.len);
}

/// `line` without up to `indent` leading spaces, and without a trailing `\r`.
fn dedent(line: []const u8, indent: u32) []const u8 {
    assert(line.len <= doc_bytes_max);
    assert(indent < 64);
    var start: u32 = 0;
    while (start < indent and start < line.len and line[start] == ' ') start += 1;
    return std.mem.trimEnd(u8, line[start..], "\r");
}

/// Whether `text` compiles as a file of its own (see the module comment).
pub fn classify(text: []const u8) Kind {
    assert(text.len <= doc_bytes_max);
    const starts = [_][]const u8{ "pub ", "fn ", "test \"" };
    var lines = std.mem.splitScalar(u8, text, '\n');
    var count: u32 = 0;
    while (lines.next()) |line| : (count += 1) {
        for (starts) |start| {
            if (std.mem.startsWith(u8, line, start)) return .file;
        }
        if (is_import(line)) return .file;
    }
    assert(count > 0);
    return .body;
}

/// Whether `line` is `const <name> = @import(...` at column 0.
fn is_import(line: []const u8) bool {
    assert(line.len <= doc_bytes_max);
    if (!std.mem.startsWith(u8, line, "const ")) return false;
    const equals = std.mem.indexOf(u8, line, " = ") orelse return false;
    assert(equals >= "const".len);
    return std.mem.startsWith(u8, line[equals + 3 ..], "@import(");
}

/// Whether a body makes its own story, so the wrapper must not pass one.
fn declares_story(text: []const u8) bool {
    assert(text.len <= doc_bytes_max);
    const declared = std.mem.indexOf(u8, text, "var story") != null or
        std.mem.indexOf(u8, text, "const story") != null;
    assert(declared or std.mem.indexOf(u8, text, "var story") == null);
    return declared;
}

/// The Zig file for one block of `doc` (the Markdown file's name).
pub fn render_block(arena: Allocator, doc: []const u8, block: Block) Allocator.Error![]u8 {
    assert(doc.len > 0);
    assert(block.line > 0);
    var out: std.ArrayList(u8) = .empty;
    const header = "// Generated by tools/doctest.zig from {s}:{d}.\n";
    try out.print(arena, header, .{ doc, block.line });
    if (classify(block.text) == .file) {
        try out.appendSlice(arena, block.text);
        return out.items;
    }
    try out.appendSlice(arena, "const std = @import(\"std\");\n");
    try out.appendSlice(arena, "const inkz = @import(\"inkz\");\n\n");
    if (declares_story(block.text)) {
        try out.appendSlice(arena, "pub fn sample(gpa: std.mem.Allocator, io: std.Io) !void {\n");
        try out.appendSlice(arena, "    _ = .{ gpa, io };\n");
    } else {
        try out.appendSlice(arena, "pub fn sample(gpa: std.mem.Allocator, io: std.Io, " ++
            "story: *inkz.Story) !void {\n");
        try out.appendSlice(arena, "    _ = .{ gpa, io, story };\n");
    }
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, block.text, "\n"), '\n');
    while (lines.next()) |line| {
        if (line.len > 0) try out.appendSlice(arena, "    ");
        try out.appendSlice(arena, line);
        try out.append(arena, '\n');
    }
    try out.appendSlice(arena, "}\n");
    return out.items;
}

/// The name of the generated file for a block: the doc's name without `.md`, then the line.
pub fn block_file_name(arena: Allocator, doc: []const u8, line: u32) Allocator.Error![]u8 {
    assert(doc.len > 0);
    assert(line > 0);
    const stem = if (std.mem.endsWith(u8, doc, ".md")) doc[0 .. doc.len - 3] else doc;
    return std.fmt.allocPrint(arena, "{s}_{d}.zig", .{ stem, line });
}

/// One test per block: referencing every declaration compiles it, and a file block's own
/// tests run.
fn render_root_test(
    arena: Allocator,
    out: *std.ArrayList(u8),
    doc: []const u8,
    line: u32,
) Allocator.Error!void {
    assert(doc.len > 0);
    assert(line > 0);
    const file_name = try block_file_name(arena, doc, line);
    try out.print(arena, "test \"{s}:{d}\" {{\n", .{ doc, line });
    try out.print(arena, "    std.testing.refAllDecls(@import(\"{s}\"));\n}}\n\n", .{file_name});
}

fn write_doc(
    arena: Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    path: []const u8,
    root: *std.ArrayList(u8),
) !u32 {
    assert(path.len > 0);
    assert(root.items.len > 0);
    const markdown = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(doc_bytes_max));
    const doc = std.fs.path.basename(path);
    const blocks = try extract(arena, markdown);
    for (blocks) |block| {
        const file_name = try block_file_name(arena, doc, block.line);
        const data = try render_block(arena, doc, block);
        try directory.writeFile(io, .{ .sub_path = file_name, .data = data });
        try render_root_test(arena, root, doc, block.line);
    }
    return @intCast(blocks.len);
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const arguments = try init.minimal.args.toSlice(arena);
    assert(arguments.len > 0);
    if (arguments.len < 3) {
        std.debug.print("usage: doctest <output directory> <doc.md>...\n", .{});
        std.process.exit(2);
    }
    try std.Io.Dir.cwd().createDirPath(io, arguments[1]);
    var directory = try std.Io.Dir.cwd().openDir(io, arguments[1], .{});
    defer directory.close(io);
    var root: std.ArrayList(u8) = .empty;
    try root.appendSlice(arena, "// Generated by tools/doctest.zig.\n");
    try root.appendSlice(arena, "const std = @import(\"std\");\n\n");
    var blocks_count: u32 = 0;
    for (arguments[2..]) |path| blocks_count += try write_doc(arena, io, directory, path, &root);
    try directory.writeFile(io, .{ .sub_path = "root.zig", .data = root.items });
    assert(blocks_count <= blocks_max * arguments.len);
}

test "extract finds zig blocks only, with their lines, and dedents indented fences" {
    // Goal: the extraction rules of the module comment. Method: a document with a zig block,
    // a sh block and an indented zig block inside a list item.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const markdown =
        \\# Title
        \\```zig
        \\const a = 1;
        \\```
        \\```sh
        \\zig build
        \\```
        \\1. Item:
        \\   ```zig
        \\   try story.cont();
        \\   ```
    ;
    const blocks = try extract(arena_state.allocator(), markdown);
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqual(@as(u32, 2), blocks[0].line);
    try std.testing.expectEqualStrings("const a = 1;\n", blocks[0].text);
    try std.testing.expectEqual(@as(u32, 9), blocks[1].line);
    try std.testing.expectEqualStrings("try story.cont();\n", blocks[1].text);
}

test "an unterminated block is an error" {
    // Goal: a missing closing fence is reported, not silently dropped. Method: one open fence.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const result = extract(arena_state.allocator(), "```zig\nconst a = 1;\n");
    try std.testing.expectError(error.UnterminatedBlock, result);
}

test "classify tells files from bodies" {
    // Goal: the file/body rule. Method: one example of each starting form, and bodies whose
    // indented or non-import lines look like declarations.
    try std.testing.expectEqual(Kind.file, classify("const std = @import(\"std\");\n"));
    try std.testing.expectEqual(Kind.file, classify("pub fn main() void {}\n"));
    try std.testing.expectEqual(Kind.file, classify("fn helper() void {}\n"));
    try std.testing.expectEqual(Kind.file, classify("test \"x\" {}\n"));
    try std.testing.expectEqual(Kind.body, classify("const line = try story.cont();\n"));
    try std.testing.expectEqual(Kind.body, classify("if (x) {\n    pub_thing();\n}\n"));
}

test "a body is wrapped with gpa, io and a story unless it makes its own" {
    // Goal: the wrapper of the module comment. Method: render two bodies and look for the
    // signature and the indented text.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const borrowed = try render_block(arena, "A.md", .{ .line = 3, .text = "_ = story;\n" });
    try std.testing.expect(std.mem.indexOf(u8, borrowed, "story: *inkz.Story) !void {") != null);
    try std.testing.expect(std.mem.indexOf(u8, borrowed, "\n    _ = story;\n}") != null);
    const own = try render_block(arena, "A.md", .{ .line = 5, .text = "var story: u8 = 0;\n" });
    try std.testing.expect(std.mem.indexOf(u8, own, "io: std.Io) !void {") != null);
    try std.testing.expectEqualStrings("A_5.zig", try block_file_name(arena, "A.md", 5));
}
