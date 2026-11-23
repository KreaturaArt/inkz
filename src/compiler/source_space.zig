//! The source space: every file of a compilation, comment-free, laid end
//! to end in one buffer and parsed into one tree, so token and node indices are global; a
//! file table maps offsets back to `file:line:column`.
//!
//! INCLUDE follows ink's InkParser.IncludeStatement: the name is resolved against the root
//! file's directory (ink's DefaultFileHandler, with inklecate in that directory), a file
//! that is still open (an ancestor in the include chain) is a recursive include, and a file
//! included twice is loaded twice. Files are added depth first with an explicit stack:
//! each is appended to the space and parsed once, and its INCLUDEs, read from its region,
//! add the next files.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const grammar = @import("grammar.zig");
const lexical = @import("lexical.zig");
const ast_module = @import("ast.zig");
const limits = @import("../core/limits.zig");
const NodeIndex = ast_module.NodeIndex;
const Ast = ast_module.Ast;

pub const no_file = std.math.maxInt(u32);
pub const file_bytes_max = 16 * 1024 * 1024;

pub const Problem = struct {
    pub const Code = enum(u8) {
        include_cycle,
        include_not_found,
        include_too_deep,
        include_too_many,
    };
    code: Code,
    /// The INCLUDE's offset in the space.
    offset: u32,
};

pub const File = struct {
    /// The root's path as given; an included file's is the root's directory joined with the
    /// name in the INCLUDE.
    path: []const u8,
    start: u32,
    end: u32,
    /// The including file (`no_file` for the root) and how deep the chain is.
    parent: u32,
    depth: u32,
};

pub const Location = struct { path: []const u8, line: u32, column: u32 };

pub const Space = struct {
    arena: std.heap.ArenaAllocator,
    files: []const File,
    parsed: grammar.Parsed,
    /// An INCLUDE node's file (`no_file` if it couldn't be included).
    included: std.AutoHashMapUnmanaged(u32, u32),
    problems: []const Problem,
    /// The offsets of the space's newlines, in order: built by the first `locate` (one
    /// allocation), so a position costs two binary searches instead of a scan of the text.
    newlines: ?[]u32 = null,

    pub fn deinit(space: *Space, gpa: Allocator) void {
        assert(space.parsed.roots.len == space.files.len);
        if (space.newlines) |newlines| gpa.free(newlines);
        space.included.deinit(gpa);
        space.parsed.deinit(gpa);
        space.arena.deinit();
        space.* = undefined;
    }

    /// The story an INCLUDE node brings in, if it could be included.
    pub fn included_story(space: *const Space, include: NodeIndex) ?NodeIndex {
        assert(space.parsed.tree.tag(include) == .include);
        const file = space.included.get(include.to_int()) orelse return null;
        if (file == no_file) return null;
        return space.parsed.roots[file];
    }

    /// The file, line and column (from 1) of an offset in the space, from the newline table
    /// (built here the first time). Columns count the comment-free text, as ink's
    /// CommentEliminator leaves it.
    pub fn locate(space: *Space, gpa: Allocator, offset: u32) Allocator.Error!Location {
        assert(offset <= space.parsed.source.len);
        if (space.newlines == null) space.newlines = try newline_offsets(gpa, space.parsed.source);
        const newlines = space.newlines.?;
        const file = space.files[space.file_at(offset)];
        assert(file.start <= offset and offset <= file.end);
        // Newlines before `offset` and before the file's start: the lines in between.
        const before = lower_bound(newlines, offset);
        const before_file = lower_bound(newlines, file.start);
        assert(before >= before_file);
        const line_start = if (before > before_file) newlines[before - 1] + 1 else file.start;
        return .{
            .path = file.path,
            .line = @intCast(before - before_file + 1),
            .column = offset - line_start + 1,
        };
    }

    /// The file an offset is in: the last one that starts at or before it (files are laid
    /// end to end, so at a boundary the later file wins, as the scan does).
    pub fn file_at(space: *const Space, offset: u32) usize {
        var low: usize = 0;
        var high: usize = space.files.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (space.files[middle].start <= offset) low = middle + 1 else high = middle;
        }
        assert(low > 0);
        return low - 1;
    }

    /// `locate` by scanning: the file table linearly, the text for newlines. The reference
    /// the table is tested against.
    pub fn location_scan(space: *const Space, offset: u32) Location {
        assert(offset <= space.parsed.source.len);
        var file_index: usize = 0;
        for (space.files, 0..) |file, position| {
            if (offset >= file.start and offset <= file.end) file_index = position;
        }
        const file = space.files[file_index];
        const text = space.parsed.source[file.start..];
        const position = lexical.line_and_column(text, offset - file.start);
        return .{ .path = file.path, .line = position.line, .column = position.column };
    }
};

/// The offsets of `text`'s newlines, in one allocation.
fn newline_offsets(gpa: Allocator, text: []const u8) Allocator.Error![]u32 {
    assert(text.len < std.math.maxInt(u32));
    const offsets = try gpa.alloc(u32, std.mem.count(u8, text, "\n"));
    var count: usize = 0;
    for (text, 0..) |byte, at| {
        if (byte != '\n') continue;
        offsets[count] = @intCast(at);
        count += 1;
    }
    return offsets;
}

/// How many of `sorted` are below `value`.
fn lower_bound(sorted: []const u32, value: u32) usize {
    var low: usize = 0;
    var high: usize = sorted.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (sorted[middle] < value) low = middle + 1 else high = middle;
    }
    return low;
}

/// A file's text without its UTF-8 byte order mark, which .NET's File.ReadAllText drops
/// before inklecate parses it.
pub fn without_bom(text: []const u8) []const u8 {
    const bom = "\xEF\xBB\xBF";
    return if (std.mem.startsWith(u8, text, bom)) text[bom.len..] else text;
}

/// A file's text as .NET's File.ReadAllText gives it to inklecate: without its byte order
/// mark, and with each ill-formed UTF-8 sequence replaced by U+FFFD (its maximal subparts,
/// as .NET's decoder and `std.unicode.fmtUtf8` replace them). Invalid bytes once compiled
/// to JSON that no JSON reader loads. Valid text is returned as it is; other text is copied
/// into `gpa`, and `allocated` says which.
pub const Decoded = struct {
    text: []const u8,
    allocated: bool,

    pub fn of(gpa: Allocator, file_text: []const u8) Allocator.Error!Decoded {
        const text = without_bom(file_text);
        if (std.unicode.utf8ValidateSlice(text)) return .{ .text = text, .allocated = false };
        var decoded: std.Io.Writer.Allocating = .init(gpa);
        errdefer decoded.deinit();
        decoded.writer.print("{f}", .{std.unicode.fmtUtf8(text)}) catch return error.OutOfMemory;
        const copy = try decoded.toOwnedSlice();
        assert(std.unicode.utf8ValidateSlice(copy));
        return .{ .text = copy, .allocated = true };
    }

    pub fn deinit(decoded: Decoded, gpa: Allocator) void {
        if (decoded.allocated) gpa.free(decoded.text);
    }
};

/// An INCLUDE of a parsed file: its node, name and offset in the space.
const Include = struct { node: NodeIndex, name: []const u8, offset: u32 };

/// A file of an in-memory compilation: its path, as the root's or an INCLUDE's path names
/// it, and its text.
pub const MemoryFile = struct { path: []const u8, text: []const u8 };

/// Where a compilation's files come from: a directory, or files in memory (which the
/// swarm compiles INCLUDEs from without touching the file system).
pub const Files = union(enum) {
    directory: struct { io: std.Io, directory: std.Io.Dir },
    memory: []const MemoryFile,
};

/// Loads `root_path` (relative to `directory`) and everything it includes, and parses it.
pub fn load(
    gpa: Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    root_path: []const u8,
    bounds: limits.CompilerLimits,
) !Space {
    const files: Files = .{ .directory = .{ .io = io, .directory = directory } };
    return load_files(gpa, files, root_path, bounds);
}

/// Loads `root_path` from `files` and everything it includes, and parses it.
pub fn load_files(
    gpa: Allocator,
    files: Files,
    root_path: []const u8,
    bounds: limits.CompilerLimits,
) !Space {
    assert(bounds.include_files_max > 0);
    assert(root_path.len > 0);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    var discovery: Discovery = .{
        .gpa = gpa,
        .arena = arena_state.allocator(),
        .files_from = files,
        .bounds = bounds,
        .parser = try grammar.SpaceParser.init(gpa, bounds),
    };
    errdefer discovery.included.deinit(gpa);
    const parsed = parsed: {
        errdefer discovery.parser.deinit(gpa);
        try discovery.run(root_path);
        break :parsed try discovery.parser.finish(gpa);
    };
    assert(parsed.roots.len == discovery.files.items.len);
    // The arena moves into the space only after its last allocation.
    return .{
        .arena = arena_state,
        .files = discovery.files.items,
        .parsed = parsed,
        .included = discovery.included,
        .problems = discovery.problems.items,
    };
}

const Discovery = struct {
    gpa: Allocator,
    arena: Allocator,
    files_from: Files,
    bounds: limits.CompilerLimits,
    parser: grammar.SpaceParser,
    files: std.ArrayList(File) = .empty,
    /// Each file's INCLUDEs, in source order.
    includes: std.ArrayList([]const Include) = .empty,
    included: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    problems: std.ArrayList(Problem) = .empty,

    fn run(discovery: *Discovery, root_path: []const u8) !void {
        const text = try discovery.read(root_path) orelse return error.FileNotFound;
        try discovery.parse_file(root_path, text, no_file, 0);
        const Frame = struct { file: u32, next: u32 };
        var stack: std.ArrayList(Frame) = .empty;
        try stack.append(discovery.arena, .{ .file = 0, .next = 0 });
        const root_directory = std.fs.path.dirname(root_path) orelse "";
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            const includes = discovery.includes.items[top.file];
            if (top.next == includes.len) {
                _ = stack.pop();
                continue;
            }
            const include = includes[top.next];
            top.next += 1;
            const parent = top.file;
            const target = try discovery.follow(parent, include, root_directory, stack.items);
            try discovery.included.put(discovery.gpa, include.node.to_int(), target);
            if (target != no_file) try stack.append(discovery.arena, .{
                .file = target,
                .next = 0,
            });
        }
        assert(discovery.files.items.len == discovery.includes.items.len);
    }

    /// One INCLUDE of `parent`: its file, or `no_file` with a problem recorded.
    fn follow(
        discovery: *Discovery,
        parent: u32,
        include_found: Include,
        root_directory: []const u8,
        chain: anytype,
    ) !u32 {
        const path = if (root_directory.len == 0)
            include_found.name
        else
            try std.fmt.allocPrint(discovery.arena, "{s}/{s}", .{
                root_directory,
                include_found.name,
            });
        for (chain) |frame| {
            if (std.mem.eql(u8, discovery.files.items[frame.file].path, path)) {
                return discovery.record(.include_cycle, include_found.offset);
            }
        }
        const depth = discovery.files.items[parent].depth + 1;
        if (depth > discovery.bounds.include_depth_max) {
            return discovery.record(.include_too_deep, include_found.offset);
        }
        if (discovery.files.items.len == discovery.bounds.include_files_max) {
            return discovery.record(.include_too_many, include_found.offset);
        }
        const text = try discovery.read(path) orelse {
            return discovery.record(.include_not_found, include_found.offset);
        };
        try discovery.parse_file(path, text, parent, depth);
        return @intCast(discovery.files.items.len - 1);
    }

    fn record(discovery: *Discovery, code: Problem.Code, offset: u32) !u32 {
        assert(offset <= discovery.parser.buffer.items.len);
        try discovery.problems.append(discovery.arena, .{ .code = code, .offset = offset });
        return no_file;
    }

    /// The file's text, or null if it can't be read.
    fn read(discovery: *Discovery, path: []const u8) !?[]const u8 {
        assert(path.len > 0);
        const text = switch (discovery.files_from) {
            .directory => |from| from.directory.readFileAlloc(
                from.io,
                path,
                discovery.arena,
                .limited(file_bytes_max),
            ) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return null,
            },
            .memory => |files| text: {
                for (files) |file| {
                    if (!std.mem.eql(u8, file.path, path)) continue;
                    if (file.text.len > file_bytes_max) return null;
                    break :text file.text;
                }
                return null;
            },
        };
        // The arena frees the copy.
        return (try Decoded.of(discovery.arena, text)).text;
    }

    /// Appends a file to the space and parses it, the only parse it gets, and records it
    /// with its INCLUDEs (before the next file grows the tree).
    fn parse_file(
        discovery: *Discovery,
        path: []const u8,
        text: []const u8,
        parent: u32,
        depth: u32,
    ) !void {
        const parser = &discovery.parser;
        const start: u32 = @intCast(parser.buffer.items.len);
        const root = try parser.add(discovery.gpa, text);
        // The regions so far, valid until the next file is added.
        const tree = parser.machine.finish_regions(root);
        var includes: std.ArrayList(Include) = .empty;
        var nodes = tree.walk(discovery.gpa, root);
        defer nodes.deinit();
        while (try nodes.next()) |step| {
            if (step.leave or tree.tag(step.node) != .include) continue;
            const token = tree.data[step.node.to_int()];
            const offset = parser.workspace.token_starts[token];
            const name = parser.buffer.items[offset..parser.workspace.token_ends[token]];
            try includes.append(discovery.arena, .{
                .node = step.node,
                .name = try discovery.arena.dupe(u8, name),
                .offset = offset,
            });
        }
        try discovery.files.append(discovery.arena, .{
            .path = path,
            .start = start,
            .end = @intCast(parser.buffer.items.len),
            .parent = parent,
            .depth = depth,
        });
        try discovery.includes.append(discovery.arena, includes.items);
    }
};

// Tests.

const fixtures = "test/fixture/original/runtime/misc";

fn load_fixture(gpa: Allocator, comptime name: []const u8) !Space {
    comptime assert(std.mem.endsWith(u8, name, ".ink"));
    var directory = try std.Io.Dir.cwd().openDir(std.testing.io, fixtures, .{});
    defer directory.close(std.testing.io);
    return load(gpa, std.testing.io, directory, name, .{});
}

test "include.ink: two files included, laid out after the root" {
    const gpa = std.testing.allocator;
    var space = try load_fixture(gpa, "include.ink");
    defer space.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), space.files.len);
    try std.testing.expectEqualStrings("includes/included_file.ink", space.files[1].path);
    try std.testing.expectEqualStrings("includes/included_file_2.ink", space.files[2].path);
    try std.testing.expectEqual(@as(usize, 0), space.problems.len);
    try std.testing.expectEqual(@as(u32, 0), space.parsed.diagnostics_count);
    try std.testing.expectEqual(@as(u32, 2), space.included.count());
    // The root's text comes first; each file's offsets locate in that file.
    const second = try space.locate(gpa, space.files[2].start + 3);
    try std.testing.expectEqualStrings("includes/included_file_2.ink", second.path);
    try std.testing.expectEqual(@as(u32, 1), second.line);
    try std.testing.expectEqual(@as(u32, 4), second.column);
}

test "nested_include.ink: an included file's INCLUDE resolves from the root's directory" {
    const gpa = std.testing.allocator;
    var space = try load_fixture(gpa, "nested_include.ink");
    defer space.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), space.problems.len);
    try std.testing.expect(space.files.len >= 3);
    for (space.files[1..]) |file| {
        try std.testing.expect(std.mem.startsWith(u8, file.path, "includes/"));
    }
    try std.testing.expectEqual(@as(u32, 1), space.files[space.files.len - 1].parent);
}

test "an include cycle is a diagnostic on the INCLUDE, not a hang" {
    const gpa = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    try temporary.dir.writeFile(io, .{ .sub_path = "a.ink", .data = "INCLUDE b.ink\nA\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "b.ink", .data = "B\nINCLUDE a.ink\n" });
    var space = try load(gpa, io, temporary.dir, "a.ink", .{});
    defer space.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), space.files.len);
    try std.testing.expectEqual(@as(u32, 2), space.parsed.parses);
    try std.testing.expectEqual(@as(usize, 1), space.problems.len);
    try std.testing.expectEqual(Problem.Code.include_cycle, space.problems[0].code);
    const where = try space.locate(gpa, space.problems[0].offset);
    try std.testing.expectEqualStrings("b.ink", where.path);
    try std.testing.expectEqual(@as(u32, 2), where.line);
}

test "a missing include and the include limits are diagnostics" {
    const gpa = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    try temporary.dir.writeFile(io, .{
        .sub_path = "a.ink",
        .data = "INCLUDE missing.ink\nINCLUDE b.ink\n",
    });
    try temporary.dir.writeFile(io, .{ .sub_path = "b.ink", .data = "INCLUDE c.ink\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "c.ink", .data = "C\n" });
    var space = try load(gpa, io, temporary.dir, "a.ink", .{ .include_depth_max = 1 });
    defer space.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), space.problems.len);
    try std.testing.expectEqual(Problem.Code.include_not_found, space.problems[0].code);
    try std.testing.expectEqual(Problem.Code.include_too_deep, space.problems[1].code);
    const deep = try space.locate(gpa, space.problems[1].offset);
    try std.testing.expectEqualStrings("b.ink", deep.path);
}

test "files that fit the source bound one by one but not together are an error" {
    // With source_bytes_max 16, each 12-byte file parses on its own; the space of both
    // (24 bytes) is too large, before any u32 offset is computed.
    const gpa = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    try temporary.dir.writeFile(io, .{ .sub_path = "a.ink", .data = "INCLUDE b.k\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "b.k", .data = "Twelve bytes" });
    try std.testing.expectError(
        error.SourceTooLarge,
        load(gpa, io, temporary.dir, "a.ink", .{ .source_bytes_max = 16 }),
    );
}

test "compile_file: a story nested too deep is CompileFailed" {
    // The public entry turns the parser's failures on a file into CompileFailed.
    const compile = @import("compile.zig");
    const gpa = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    var text: [601]u8 = undefined;
    @memset(text[0..300], '{');
    text[300] = 'x';
    @memset(text[301..], '}');
    try temporary.dir.writeFile(io, .{ .sub_path = "deep.ink", .data = &text });
    try std.testing.expectError(
        error.CompileFailed,
        compile.compile_file(gpa, io, temporary.dir, "deep.ink"),
    );
}

fn load_and_free(gpa: Allocator, directory: std.Io.Dir) !void {
    var space = try load(gpa, std.testing.io, directory, "a.ink", .{});
    space.deinit(gpa);
}

test "loading a space frees everything whichever allocation fails" {
    // A failed shrink in the workspace's settle once left its arrays of different lengths
    // for deinit to trip on; every other failure frees what was allocated.
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    try temporary.dir.writeFile(io, .{ .sub_path = "a.ink", .data = "INCLUDE b.ink\nA\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "b.ink", .data = "B\n" });
    try @import("../core/allocation_failures.zig").check(load_and_free, .{temporary.dir});
}

/// Three files with INCLUDEs and block comments that span lines, in a temporary directory.
fn three_files(gpa: Allocator, directory: std.Io.Dir) !Space {
    const io = std.testing.io;
    try directory.writeFile(io, .{
        .sub_path = "a.ink",
        .data = "INCLUDE b.ink\nA one /* a\ncomment */ two\n\nINCLUDE c.ink\nA end",
    });
    try directory.writeFile(io, .{ .sub_path = "b.ink", .data = "B\n/* x\n\ny */B two\n" });
    try directory.writeFile(io, .{ .sub_path = "c.ink", .data = "C // note\nC two\n" });
    return load(gpa, io, directory, "a.ink", .{});
}

test "each file of a space is parsed once" {
    // Its INCLUDEs are read from its own region, so the files aren't parsed again to find
    // them (P17.20).
    const gpa = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var space = try three_files(gpa, temporary.dir);
    defer space.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), space.files.len);
    try std.testing.expectEqual(@as(u32, 3), space.parsed.parses);
    try std.testing.expectEqual(@as(u32, 0), space.parsed.retries());
    try std.testing.expectEqual(@as(u32, 2), space.included.count());
    var stories: [2]NodeIndex = undefined;
    var count: usize = 0;
    var nodes = space.parsed.tree.walk(gpa, space.parsed.roots[0]);
    defer nodes.deinit();
    while (try nodes.next()) |step| {
        if (step.leave or space.parsed.tree.tag(step.node) != .include) continue;
        stories[count] = space.included_story(step.node).?;
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(space.parsed.roots[1], stories[0]);
    try std.testing.expectEqual(space.parsed.roots[2], stories[1]);
}

test "a file that fills the workspace is parsed again on its own" {
    // Dense arithmetic in the included file needs a larger workspace: only that file is
    // parsed again, and the root's tree and INCLUDE stay as they were.
    const gpa = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, "~ temp x = 1");
    for (0..2000) |_| try text.appendSlice(gpa, "+1");
    try text.appendSlice(gpa, "\n{x}\n");
    try temporary.dir.writeFile(io, .{ .sub_path = "a.ink", .data = "INCLUDE b.ink\nA\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "b.ink", .data = text.items });
    var space = try load(gpa, io, temporary.dir, "a.ink", .{});
    defer space.deinit(gpa);
    try std.testing.expect(space.parsed.retries() > 0);
    try std.testing.expectEqual(space.parsed.parses - space.parsed.retries(), 2);
    try std.testing.expectEqual(@as(u32, 0), space.parsed.diagnostics_count);
    var iterator = space.included.iterator();
    const include: NodeIndex = .from_int(iterator.next().?.key_ptr.*);
    try std.testing.expectEqual(space.parsed.roots[1], space.included_story(include).?);
    const where = try space.locate(gpa, space.parsed.workspace.token_starts[
        space.parsed.tree.data[include.to_int()]
    ]);
    try std.testing.expectEqualStrings("a.ink", where.path);
    try std.testing.expectEqual(@as(u32, 9), where.column);
}

test "the newline table locates every offset as the scan does" {
    // Every offset of a three-file space, comments and INCLUDEs among them: the same file,
    // line and column from the table as from scanning (P16.11).
    const gpa = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var space = try three_files(gpa, temporary.dir);
    defer space.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), space.files.len);
    for (0..space.parsed.source.len + 1) |at| {
        const offset: u32 = @intCast(at);
        const table = try space.locate(gpa, offset);
        const scan = space.location_scan(offset);
        try std.testing.expectEqualStrings(scan.path, table.path);
        try std.testing.expectEqual(scan.line, table.line);
        try std.testing.expectEqual(scan.column, table.column);
    }
}

test "the newline table is one allocation, made once" {
    const gpa = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var space = try three_files(gpa, temporary.dir);
    defer space.deinit(gpa);
    var counting = @import("../core/counting_allocator.zig").CountingAllocator.init(gpa);
    _ = try space.locate(counting.allocator(), 5);
    try std.testing.expectEqual(@as(u64, 1), counting.allocations_count);
    _ = try space.locate(counting.allocator(), space.files[2].start);
    try std.testing.expectEqual(@as(u64, 1), counting.allocations_count);
}

test "a file's first and last byte and a boundary locate in the right file" {
    const gpa = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var space = try three_files(gpa, temporary.dir);
    defer space.deinit(gpa);
    for (space.files, 0..) |file, index| {
        try std.testing.expect(file.end > file.start);
        // The first byte is the file's, at line 1, column 1.
        const first = try space.locate(gpa, file.start);
        if (index == 0 or space.files[index - 1].end < file.start) {
            try std.testing.expectEqualStrings(file.path, first.path);
        }
        try std.testing.expectEqual(index, space.file_at(file.start + 1));
        // The last byte is still this file's.
        try std.testing.expectEqual(index, space.file_at(file.end - 1));
        try std.testing.expectEqualStrings(file.path, (try space.locate(gpa, file.end - 1)).path);
    }
    // At a boundary (one file's end, the next one's start) the later file wins.
    try std.testing.expectEqual(space.files[1].start, space.files[0].end);
    try std.testing.expectEqual(@as(usize, 1), space.file_at(space.files[0].end));
    const boundary = try space.locate(gpa, space.files[1].start);
    try std.testing.expectEqualStrings(space.files[1].path, boundary.path);
    try std.testing.expectEqual(@as(u32, 1), boundary.line);
    try std.testing.expectEqual(@as(u32, 1), boundary.column);
}
