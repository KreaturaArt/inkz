//! Counts lines of Zig per module for `zig build code-size`: code, comments, top-level `test`
//! blocks and blank lines. A module is a directory under src/ (src/core, src/runtime, ...),
//! src's own files, tools or build.zig.

const std = @import("std");
const assert = std.debug.assert;

pub const Counts = struct {
    files: u32 = 0,
    code: u32 = 0,
    comments: u32 = 0,
    tests: u32 = 0,
    blank: u32 = 0,

    fn add(counts: *Counts, other: Counts) void {
        counts.files += other.files;
        counts.code += other.code;
        counts.comments += other.comments;
        counts.tests += other.tests;
        counts.blank += other.blank;
    }
};

/// Classifies each line of `source`. A test block starts with `test` at the start of a line
/// and ends at the next line that starts with `}`.
pub fn count(source: []const u8) Counts {
    var counts: Counts = .{ .files = 1 };
    var in_test = false;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (lines.peek() == null and line.len == 0) break;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (in_test) {
            counts.tests += 1;
            in_test = !std.mem.startsWith(u8, line, "}");
        } else if (std.mem.startsWith(u8, line, "test ") or std.mem.startsWith(u8, line, "test{")) {
            counts.tests += 1;
            in_test = !std.mem.endsWith(u8, trimmed, "}");
        } else if (trimmed.len == 0) {
            counts.blank += 1;
        } else if (std.mem.startsWith(u8, trimmed, "//")) {
            counts.comments += 1;
        } else {
            counts.code += 1;
        }
    }
    return counts;
}

/// The module `path` belongs to: `src/<directory>`, `src` for src's own files, or the first
/// path component.
pub fn module_of(path: []const u8) []const u8 {
    assert(path.len > 0);
    const first = std.mem.indexOfScalar(u8, path, '/') orelse return path;
    if (!std.mem.eql(u8, path[0..first], "src")) return path[0..first];
    const second = std.mem.indexOfScalarPos(u8, path, first + 1, '/') orelse return "src";
    return path[0..second];
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const arguments = try init.minimal.args.toSlice(arena);
    var modules: std.StringArrayHashMapUnmanaged(Counts) = .empty;
    for (arguments[1..]) |argument| {
        var paths: std.ArrayList([]const u8) = .empty;
        try collect(arena, io, argument, &paths);
        for (paths.items) |path| {
            const source = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
            const entry = try modules.getOrPutValue(arena, module_of(path), .{});
            entry.value_ptr.add(count(source));
        }
    }
    const Context = struct {
        keys: []const []const u8,
        pub fn lessThan(context: @This(), a: usize, b: usize) bool {
            return std.mem.order(u8, context.keys[a], context.keys[b]) == .lt;
        }
    };
    modules.sort(Context{ .keys = modules.keys() });
    try print_table(io, modules.keys(), modules.values());
}

fn print_table(io: std.Io, names: []const []const u8, rows: []const Counts) !void {
    assert(names.len == rows.len);
    var buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(io, &buffer);
    const writer = &file_writer.interface;
    try writer.print("| Module | Files | Code | Comments | Tests | Blank |\n", .{});
    try writer.print("|---|---:|---:|---:|---:|---:|\n", .{});
    var total: Counts = .{};
    for (names, rows) |name, row| {
        try print_row(writer, name, row);
        total.add(row);
    }
    try print_row(writer, "**Total**", total);
    try writer.flush();
}

fn print_row(writer: *std.Io.Writer, name: []const u8, row: Counts) !void {
    try writer.print("| {s} | {d} | {d} | {d} | {d} | {d} |\n", .{
        name, row.files, row.code, row.comments, row.tests, row.blank,
    });
}

/// `argument` if it is a `.zig` file, or every `.zig` file below it.
fn collect(
    arena: std.mem.Allocator,
    io: std.Io,
    argument: []const u8,
    paths: *std.ArrayList([]const u8),
) !void {
    if (std.mem.endsWith(u8, argument, ".zig")) return paths.append(arena, argument);
    var directory = try std.Io.Dir.cwd().openDir(io, argument, .{ .iterate = true });
    defer directory.close(io);
    var walker = try directory.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const trimmed = std.mem.trimEnd(u8, argument, "/");
        try paths.append(arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ trimmed, entry.path }));
    }
}

test "lines are code, comments, tests or blank" {
    const source =
        \\//! A module.
        \\const std = @import("std");
        \\
        \\fn f() void {
        \\    // inside
        \\}
        \\test "f" {
        \\    f();
        \\}
        \\test {}
        \\
    ;
    const counts = count(source);
    try std.testing.expectEqual(@as(u32, 3), counts.code);
    try std.testing.expectEqual(@as(u32, 2), counts.comments);
    try std.testing.expectEqual(@as(u32, 4), counts.tests);
    try std.testing.expectEqual(@as(u32, 1), counts.blank);
}

test "a file's module is its directory under src, or its first path component" {
    try std.testing.expectEqualStrings("src/core", module_of("src/core/program.zig"));
    try std.testing.expectEqualStrings("src", module_of("src/root.zig"));
    try std.testing.expectEqualStrings("tools", module_of("tools/lint.zig"));
    try std.testing.expectEqualStrings("build.zig", module_of("build.zig"));
}
