//! Snapshot files: a test renders a value as text and checks it against
//! `<name>.snap` in a directory. With `SNAP_UPDATE=1` (the build's `-Dsnap-update`) the file
//! is written instead, so reviewing a snapshot change is reading a diff.

const std = @import("std");
const assert = std.debug.assert;

pub const extension = ".snap";
pub const file_bytes_max = 4 * 1024 * 1024;

pub const Outcome = enum {
    matched,
    /// The snapshot was (re)written (update mode).
    written,
    /// The snapshot differs (`report` prints how).
    mismatched,
    /// There is no snapshot yet (and not in update mode).
    missing,
};

/// Whether snapshots should be rewritten: the build option, or SNAP_UPDATE=1 at run time.
pub fn update_requested(arena: std.mem.Allocator, environ: std.process.Environ, option: bool) bool {
    assert(@TypeOf(option) == bool);
    if (option) return true;
    const value = environ.getAlloc(arena, "SNAP_UPDATE") catch return false;
    assert(value.len < file_bytes_max);
    return std.mem.eql(u8, value, "1");
}

/// Compares `actual` with `<directory>/<name>.snap`, or writes it if `update`.
pub fn check(
    arena: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    name: []const u8,
    actual: []const u8,
    update: bool,
) !Outcome {
    assert(name.len > 0);
    assert(actual.len < file_bytes_max);
    const path = try std.fmt.allocPrint(arena, "{s}{s}", .{ name, extension });
    const limit: std.Io.Limit = .limited(file_bytes_max);
    const expected = directory.readFileAlloc(io, path, arena, limit) catch |err| {
        switch (err) {
            error.FileNotFound => {
                if (!update) return .missing;
                try directory.writeFile(io, .{ .sub_path = path, .data = actual });
                return .written;
            },
            else => return err,
        }
    };
    if (std.mem.eql(u8, expected, actual)) return .matched;
    if (update) {
        try directory.writeFile(io, .{ .sub_path = path, .data = actual });
        return .written;
    }
    return .mismatched;
}

/// Prints a failed check: the first differing line, or how to create a missing snapshot.
pub fn report(
    arena: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    name: []const u8,
    actual: []const u8,
) !void {
    assert(actual.len < file_bytes_max);
    assert(name.len > 0);
    const path = try std.fmt.allocPrint(arena, "{s}{s}", .{ name, extension });
    const expected = directory.readFileAlloc(io, path, arena, .limited(file_bytes_max)) catch {
        std.debug.print("snapshot {s} is missing; create it with SNAP_UPDATE=1\n", .{path});
        return;
    };
    const line = first_different_line(expected, actual);
    std.debug.print("snapshot {s} differs at line {d}:\n  expected: {s}\n  actual:   {s}\n", .{
        path, line.number, line.expected, line.actual,
    });
}

pub const Difference = struct {
    /// 1-based.
    number: u32,
    expected: []const u8,
    actual: []const u8,
};

/// The first line where `expected` and `actual` differ (an empty line past the end).
pub fn first_different_line(expected: []const u8, actual: []const u8) Difference {
    assert(!std.mem.eql(u8, expected, actual));
    var expected_lines = std.mem.splitScalar(u8, expected, '\n');
    var actual_lines = std.mem.splitScalar(u8, actual, '\n');
    var number: u32 = 1;
    while (true) : (number += 1) {
        const left = expected_lines.next();
        const right = actual_lines.next();
        assert(left != null or right != null);
        if (left == null or right == null or !std.mem.eql(u8, left.?, right.?)) {
            return .{ .number = number, .expected = left orelse "", .actual = right orelse "" };
        }
    }
}

test "first_different_line finds the line" {
    // Self-test of the diff report: a change on line 2, and an extra line.
    const changed = first_different_line("a\nb\nc", "a\nx\nc");
    try std.testing.expectEqual(@as(u32, 2), changed.number);
    try std.testing.expectEqualStrings("b", changed.expected);
    try std.testing.expectEqualStrings("x", changed.actual);
    const longer = first_different_line("a", "a\nb");
    try std.testing.expectEqual(@as(u32, 2), longer.number);
    try std.testing.expectEqualStrings("", longer.expected);
}

test "check matches, reports, and writes in update mode" {
    // Self-test of the harness: in a temporary directory, a missing
    // snapshot, then writing it in update mode, matching it, and a mismatch.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = temporary.dir;
    try std.testing.expectEqual(
        Outcome.missing,
        try check(arena, io, directory, "s", "one\n", false),
    );
    try std.testing.expectEqual(
        Outcome.written,
        try check(arena, io, directory, "s", "one\n", true),
    );
    try std.testing.expectEqual(
        Outcome.matched,
        try check(arena, io, directory, "s", "one\n", false),
    );
    try std.testing.expectEqual(
        Outcome.mismatched,
        try check(arena, io, directory, "s", "two\n", false),
    );
    try std.testing.expectEqual(
        Outcome.written,
        try check(arena, io, directory, "s", "two\n", true),
    );
    try std.testing.expectEqual(
        Outcome.matched,
        try check(arena, io, directory, "s", "two\n", false),
    );
}
