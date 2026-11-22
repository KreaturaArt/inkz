//! `zig build code-size`: lines of Zig per module (a directory under src/, src's own files,
//! tools or build.zig) as code, comments, top-level `test` blocks and blank lines. tokei
//! counts the rest but can't tell tests from code, and docs/code_size.md tracks both.

const std = @import("std");
const assert = std.debug.assert;

/// Files, code, comments, tests and blank lines.
const Counts = [5]u32;

/// A test block starts with `test` at the start of a line and ends at the next line that
/// starts with `}`.
fn count(source: []const u8) Counts {
    var counts: Counts = .{ 1, 0, 0, 0, 0 };
    var in_test = false;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, source, "\n"), '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const opens_test = std.mem.startsWith(u8, line, "test ") or
            std.mem.startsWith(u8, line, "test{");
        const kind: usize = if (in_test or opens_test) 3 else if (trimmed.len == 0)
            4
        else if (std.mem.startsWith(u8, trimmed, "//")) 2 else 1;
        if (in_test) in_test = !std.mem.startsWith(u8, line, "}") else if (opens_test) {
            in_test = !std.mem.endsWith(u8, trimmed, "}");
        }
        counts[kind] += 1;
    }
    return counts;
}

/// `src/<directory>`, `src` for src's own files, or the first path component.
fn module_of(path: []const u8) []const u8 {
    assert(path.len > 0);
    const first = std.mem.indexOfScalar(u8, path, '/') orelse return path;
    if (!std.mem.eql(u8, path[0..first], "src")) return path[0..first];
    const second = std.mem.indexOfScalarPos(u8, path, first + 1, '/') orelse return "src";
    return path[0..second];
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    var modules: std.StringArrayHashMapUnmanaged(Counts) = .empty;
    for ((try init.minimal.args.toSlice(arena))[1..]) |argument| {
        var paths: std.ArrayList([]const u8) = .empty;
        if (std.mem.endsWith(u8, argument, ".zig")) try paths.append(arena, argument) else {
            var directory = try cwd.openDir(io, argument, .{ .iterate = true });
            var walker = try directory.walk(arena);
            while (try walker.next(io)) |entry| {
                if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
                try paths.append(arena, try std.fs.path.join(arena, &.{ argument, entry.path }));
            }
        }
        for (paths.items) |path| {
            const counts = count(try cwd.readFileAlloc(io, path, arena, .unlimited));
            const entry = try modules.getOrPutValue(arena, module_of(path), @splat(0));
            for (entry.value_ptr, counts) |*total, value| total.* += value;
        }
    }
    const Order = struct {
        keys: []const []const u8,
        pub fn lessThan(order: @This(), a: usize, b: usize) bool {
            return std.mem.order(u8, order.keys[a], order.keys[b]) == .lt;
        }
    };
    modules.sort(Order{ .keys = modules.keys() });
    var buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(io, &buffer);
    const writer = &file_writer.interface;
    try writer.writeAll("| Module | Files | Code | Comments | Tests | Blank |\n");
    try writer.writeAll("|---|---:|---:|---:|---:|---:|\n");
    var total: Counts = @splat(0);
    for (modules.keys(), modules.values()) |name, row| {
        try print_row(writer, name, row);
        for (&total, row) |*sum, value| sum.* += value;
    }
    try print_row(writer, "**Total**", total);
    try writer.flush();
}

fn print_row(writer: *std.Io.Writer, name: []const u8, row: Counts) !void {
    try writer.print("| {s} | {d} | {d} | {d} | {d} | {d} |\n", .{
        name, row[0], row[1], row[2], row[3], row[4],
    });
}

test "lines are code, comments, tests or blank, per module" {
    const source = "//! A module.\nconst std = @import(\"std\");\n\nfn f() void {\n" ++
        "    // inside\n}\ntest \"f\" {\n    f();\n}\ntest {}\n";
    try std.testing.expectEqual(Counts{ 1, 3, 2, 4, 1 }, count(source));
    try std.testing.expectEqualStrings("src/core", module_of("src/core/program.zig"));
    try std.testing.expectEqualStrings("src", module_of("src/root.zig"));
    try std.testing.expectEqualStrings("tools", module_of("tools/lint.zig"));
    try std.testing.expectEqualStrings("build.zig", module_of("build.zig"));
}
