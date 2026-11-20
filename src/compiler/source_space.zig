//! The source space: every file of a compilation, comment-free, laid end
//! to end in one buffer and parsed into one tree, so token and node indices are global; a
//! file table maps offsets back to `file:line:column`.
//!
//! INCLUDE follows ink's InkParser.IncludeStatement: the name is resolved against the root
//! file's directory (ink's DefaultFileHandler, with inklecate in that directory), a file
//! that is still open (an ancestor in the include chain) is a recursive include, and a file
//! included twice is loaded twice. Discovery parses each file on its own to find its
//! INCLUDEs, depth first with an explicit stack; then the space is laid out and parsed once.

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
    start: u32 = 0,
    end: u32 = 0,
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
        assert(space.files.len > 0);
        if (space.newlines) |newlines| gpa.free(newlines);
        space.included.deinit(gpa);
        space.parsed.deinit(gpa);
        space.arena.deinit();
        space.* = undefined;
    }

    /// The story an INCLUDE node brings in, if it could be included.
    pub fn included_story(space: *const Space, include: NodeIndex) ?NodeIndex {
        assert(space.files.len > 0);
        assert(space.parsed.tree.tag(include) == .include);
        const file = space.included.get(include.to_int()) orelse return null;
        if (file == no_file) return null;
        return space.parsed.roots[file];
    }

    /// The file, line and column (from 1) of an offset in the space, from the newline table
    /// (built here the first time). Columns count the comment-free text, as ink's
    /// CommentEliminator leaves it.
    pub fn locate(space: *Space, gpa: Allocator, offset: u32) Allocator.Error!Location {
        assert(space.files.len > 0);
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
        assert(space.files.len > 0);
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
        assert(space.files.len > 0);
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
    assert(count == offsets.len);
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
    assert(low <= sorted.len);
    return low;
}

/// A file's text without its UTF-8 byte order mark, which .NET's File.ReadAllText drops
/// before inklecate parses it.
pub fn without_bom(text: []const u8) []const u8 {
    const bom = "\xEF\xBB\xBF";
    const stripped = if (std.mem.startsWith(u8, text, bom)) text[bom.len..] else text;
    assert(stripped.len == text.len or stripped.len + bom.len == text.len);
    return stripped;
}

/// An INCLUDE found during discovery: its name and offset in its file.
const Include = struct { name: []const u8, offset: u32 };

/// Discovery's state for one file.
const Discovered = struct {
    text: []const u8,
    includes: []const Include,
    /// Each INCLUDE's file (or `no_file`), filled as discovery goes.
    targets: std.ArrayList(u32) = .empty,
};

/// Loads `root_path` (relative to `directory`) and everything it includes, and parses it.
pub fn load(
    gpa: Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    root_path: []const u8,
    bounds: limits.CompilerLimits,
) !Space {
    assert(bounds.include_files_max > 0);
    assert(root_path.len > 0);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();
    var discovery: Discovery = .{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .directory = directory,
        .bounds = bounds,
    };
    try discovery.run(root_path);
    var space = try discovery.lay_out();
    // The arena moves into the space only after its last allocation.
    space.arena = arena_state;
    return space;
}

const Discovery = struct {
    gpa: Allocator,
    arena: Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    bounds: limits.CompilerLimits,
    files: std.ArrayList(File) = .empty,
    discovered: std.ArrayList(Discovered) = .empty,
    /// Problems with the INCLUDE's file and its offset in that file (made global later).
    problems: std.ArrayList(struct { file: u32, problem: Problem }) = .empty,

    fn run(discovery: *Discovery, root_path: []const u8) !void {
        const text = try discovery.read(root_path) orelse return error.FileNotFound;
        try discovery.add(root_path, text, no_file, 0);
        const Frame = struct { file: u32, next: u32 };
        var stack: std.ArrayList(Frame) = .empty;
        try stack.append(discovery.arena, .{ .file = 0, .next = 0 });
        const root_directory = std.fs.path.dirname(root_path) orelse "";
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            const includes = discovery.discovered.items[top.file].includes;
            if (top.next == includes.len) {
                _ = stack.pop();
                continue;
            }
            const include = includes[top.next];
            top.next += 1;
            const parent = top.file;
            const target = try discovery.follow(parent, include, root_directory, stack.items);
            try discovery.discovered.items[parent].targets.append(discovery.arena, target);
            if (target != no_file) try stack.append(discovery.arena, .{
                .file = target,
                .next = 0,
            });
        }
        assert(discovery.files.items.len == discovery.discovered.items.len);
    }

    /// One INCLUDE of `parent`: its file, or `no_file` with a problem recorded.
    fn follow(
        discovery: *Discovery,
        parent: u32,
        include_found: Include,
        root_directory: []const u8,
        chain: anytype,
    ) !u32 {
        assert(discovery.bounds.include_files_max > 0);
        const path = if (root_directory.len == 0)
            include_found.name
        else
            try std.fmt.allocPrint(discovery.arena, "{s}/{s}", .{
                root_directory,
                include_found.name,
            });
        for (chain) |frame| {
            if (std.mem.eql(u8, discovery.files.items[frame.file].path, path)) {
                return discovery.record(parent, .include_cycle, include_found.offset);
            }
        }
        const depth = discovery.files.items[parent].depth + 1;
        if (depth > discovery.bounds.include_depth_max) {
            return discovery.record(parent, .include_too_deep, include_found.offset);
        }
        if (discovery.files.items.len == discovery.bounds.include_files_max) {
            return discovery.record(parent, .include_too_many, include_found.offset);
        }
        const text = try discovery.read(path) orelse {
            return discovery.record(parent, .include_not_found, include_found.offset);
        };
        try discovery.add(path, text, parent, depth);
        return @intCast(discovery.files.items.len - 1);
    }

    fn record(discovery: *Discovery, file: u32, code: Problem.Code, offset: u32) !u32 {
        assert(file < discovery.files.items.len);
        try discovery.problems.append(
            discovery.arena,
            .{ .file = file, .problem = .{ .code = code, .offset = offset } },
        );
        return no_file;
    }

    /// The file's text, or null if it can't be read.
    fn read(discovery: *Discovery, path: []const u8) !?[]const u8 {
        assert(path.len > 0);
        const limit: std.Io.Limit = .limited(file_bytes_max);
        const directory = discovery.directory;
        const io = discovery.io;
        const text = directory.readFileAlloc(io, path, discovery.arena, limit) catch |err| {
            switch (err) {
                error.OutOfMemory => return err,
                else => return null,
            }
        };
        return without_bom(text);
    }

    /// Parses a file on its own to find its INCLUDEs, and records it.
    fn add(
        discovery: *Discovery,
        path: []const u8,
        text: []const u8,
        parent: u32,
        depth: u32,
    ) !void {
        assert(discovery.bounds.include_files_max > 0);
        var parsed = try grammar.parse(discovery.gpa, text, discovery.bounds);
        defer parsed.deinit(discovery.gpa);
        var includes: std.ArrayList(Include) = .empty;
        var nodes: std.ArrayList(NodeIndex) = .empty;
        defer nodes.deinit(discovery.gpa);
        try collect_includes(discovery.gpa, &parsed.tree, parsed.tree.root, &nodes);
        for (nodes.items) |node| {
            const token = parsed.tree.data[node.to_int()];
            const workspace = &parsed.workspace;
            const start = workspace.token_starts[token];
            const name = parsed.source[start..workspace.token_ends[token]];
            try includes.append(discovery.arena, .{
                .name = try discovery.arena.dupe(u8, name),
                .offset = start,
            });
        }
        const clean = try discovery.arena.dupe(u8, parsed.source);
        try discovery.files.append(discovery.arena, .{
            .path = path,
            .parent = parent,
            .depth = depth,
        });
        try discovery.discovered.append(discovery.arena, .{
            .text = clean,
            .includes = includes.items,
        });
    }

    /// Lays the files end to end, parses the space, and maps each INCLUDE to its file.
    fn lay_out(discovery: *Discovery) !Space {
        assert(discovery.bounds.include_files_max > 0);
        const gpa = discovery.gpa;
        var total: usize = 0;
        for (discovery.discovered.items) |file| total += file.text.len;
        // Each file is within the bound, but together they may not be: the space's offsets
        // are u32.
        if (total > discovery.bounds.source_bytes_max) return error.SourceTooLarge;
        // The regions first: the buffer is owned by parse_space from its allocation on.
        const regions = try discovery.arena.alloc(grammar.Region, discovery.files.items.len);
        const buffer = try gpa.alloc(u8, total);
        var at: u32 = 0;
        for (discovery.discovered.items, discovery.files.items, regions) |file, *entry, *region| {
            @memcpy(buffer[at..][0..file.text.len], file.text);
            entry.start = at;
            entry.end = at + @as(u32, @intCast(file.text.len));
            region.* = .{ .start = entry.start, .end = entry.end };
            at = entry.end;
        }
        var parsed = try grammar.parse_space(gpa, buffer, regions, discovery.bounds);
        errdefer parsed.deinit(gpa);
        var included: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        errdefer included.deinit(gpa);
        try discovery.map_includes(&parsed, &included);
        const problems = try discovery.arena.alloc(Problem, discovery.problems.items.len);
        for (discovery.problems.items, problems) |entry, *problem| {
            problem.* = entry.problem;
            problem.offset += discovery.files.items[entry.file].start;
        }
        return .{
            .arena = undefined,
            .files = discovery.files.items,
            .parsed = parsed,
            .included = included,
            .problems = problems,
        };
    }

    /// Each file's INCLUDE nodes, in source order, get the files discovery found for them.
    fn map_includes(
        discovery: *Discovery,
        parsed: *const grammar.Parsed,
        included: *std.AutoHashMapUnmanaged(u32, u32),
    ) !void {
        const gpa = discovery.gpa;
        var nodes: std.ArrayList(NodeIndex) = .empty;
        defer nodes.deinit(gpa);
        for (discovery.discovered.items, parsed.roots) |file, root| {
            nodes.clearRetainingCapacity();
            try collect_includes(gpa, &parsed.tree, root, &nodes);
            // The same text parses the same way, so the INCLUDEs line up.
            assert(nodes.items.len == file.targets.items.len);
            for (nodes.items, file.targets.items) |node, target| try included.put(
                gpa,
                node.to_int(),
                target,
            );
        }
    }
};

/// The INCLUDE nodes under `root`, in source order (a pre-order walk).
fn collect_includes(
    gpa: Allocator,
    tree: *const Ast,
    root: NodeIndex,
    out: *std.ArrayList(NodeIndex),
) !void {
    assert(tree.tags.len == tree.data.len);
    var stack: std.ArrayList(NodeIndex) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, root);
    while (stack.pop()) |node| {
        const tag = tree.tag(node);
        if (tag == .include) try out.append(gpa, node);
        switch (ast_module.shape(tag)) {
            .leaf => {},
            .fixed => |count| {
                var position: u32 = count;
                while (position > 0) {
                    position -= 1;
                    try stack.append(gpa, tree.child(node, position));
                }
            },
            .list => {
                var position = tree.list(node).count;
                while (position > 0) {
                    position -= 1;
                    try stack.append(gpa, tree.item(node, position));
                }
            },
        }
    }
    assert(stack.items.len == 0);
}

// Tests.

const fixtures = "test/fixture/original/runtime/misc";

fn load_fixture(gpa: Allocator, comptime name: []const u8) !Space {
    assert(name.len > 0);
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
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        load_and_free,
        .{temporary.dir},
    );
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
