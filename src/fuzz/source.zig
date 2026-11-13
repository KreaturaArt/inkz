//! Fuzz targets for source preparation (plan P11.2): comment removal, and INCLUDE discovery
//! over files the fuzzer writes.

const std = @import("std");
const assert = std.debug.assert;
const Smith = std.testing.Smith;
const tokenizer = @import("../compiler/tokenizer.zig");
const source_space = @import("../compiler/source_space.zig");
const limits = @import("../core/limits.zig");

const input_bytes_max = 4096;

/// Bytes weighted toward what comments are made of.
const comment_weights = [_]Smith.Weight{
    .value(u8, '/', 96),
    .value(u8, '*', 96),
    .value(u8, '\n', 48),
    .value(u8, '\r', 8),
    .value(u8, '"', 16),
    .rangeAtMost(u8, 'a', 'c', 16),
    .rangeAtMost(u8, 0, 255, 1),
};

/// eliminate_comments keeps every line (so offsets map to the same lines) and only removes
/// bytes: its output is a subsequence of its input, and text without '/' is unchanged.
fn eliminate_comments(_: void, smith: *Smith) anyerror!void {
    var source: [input_bytes_max]u8 = undefined;
    var out: [input_bytes_max]u8 = undefined;
    const length = smith.sliceWeightedBytes(&source, &comment_weights);
    const input = source[0..length];
    const clean = tokenizer.eliminate_comments(input, &out);
    assert(clean.len <= input.len);
    assert(std.mem.count(u8, clean, "\n") == std.mem.count(u8, input, "\n"));
    var read: usize = 0;
    for (clean) |byte| {
        read = (std.mem.indexOfScalarPos(u8, input, read, byte) orelse unreachable) + 1;
    }
    if (std.mem.indexOfScalar(u8, input, '/') == null) assert(std.mem.eql(u8, clean, input));
}

test "fuzz: comment removal keeps lines and only removes bytes" {
    try std.testing.fuzz({}, eliminate_comments, .{ .corpus = &.{
        "a // b\nc /* d\ne */ f\n",
        "\"//\" /* unclosed\n\n",
        "///**/*/\r\n//",
    } });
}

// INCLUDE discovery.

const file_names = [_][]const u8{ "a.ink", "b.ink", "c.ink", "d.ink" };
/// What an INCLUDE may name: the files, a missing one, and a path into a missing directory.
const include_names = file_names ++ [_][]const u8{ "missing.ink", "sub/a.ink" };

const Fragment = enum { include, text, comment_include, block_include, declaration, knot };

const Context = struct { directory: std.Io.Dir };

/// Writes one file of INCLUDEs among other lines.
fn write_file(smith: *Smith, buffer: []u8) []const u8 {
    assert(buffer.len >= 1024);
    var writer: std.Io.Writer = .fixed(buffer);
    var lines: u32 = 0;
    while (lines < 8 and !smith.eosWeightedSimple(3, 1)) : (lines += 1) {
        const name = include_names[smith.index(include_names.len)];
        // Each line is short, so eight fit the buffer.
        const written = switch (smith.value(Fragment)) {
            .include => writer.print("INCLUDE {s}\n", .{name}),
            .text => writer.writeAll("Some text\n"),
            .comment_include => writer.print("// INCLUDE {s}\n", .{name}),
            .block_include => writer.print("/* INCLUDE {s} */\n", .{name}),
            .declaration => writer.print("VAR v{d} = 1\n", .{lines}),
            .knot => writer.print("=== k{d} ===\nIn a knot\n", .{lines}),
        };
        written catch unreachable;
    }
    assert(lines <= 8);
    return writer.buffered();
}

/// INCLUDE discovery on fuzzer-written files under tight bounds: a space or an error, never
/// a crash; files form a tree under the root within the bounds, laid end to end.
fn discover(context: Context, smith: *Smith) anyerror!void {
    const io = std.testing.io;
    var buffer: [1024]u8 = undefined;
    for (file_names) |name| {
        if (smith.boolWeighted(7, 1)) {
            context.directory.deleteFile(io, name) catch {};
            continue;
        }
        const data = write_file(smith, &buffer);
        try context.directory.writeFile(io, .{ .sub_path = name, .data = data });
    }
    const bounds: limits.CompilerLimits = .{
        .include_depth_max = smith.valueRangeAtMost(u32, 1, 4),
        .include_files_max = smith.valueRangeAtMost(u32, 1, 8),
    };
    assert(bounds.check() == .ok);
    const gpa = std.testing.allocator;
    var space = source_space.load(gpa, io, context.directory, "a.ink", bounds) catch return;
    defer space.deinit(gpa);
    check_space(&space, bounds);
}

fn check_space(space: *const source_space.Space, bounds: limits.CompilerLimits) void {
    assert(space.files.len > 0);
    assert(space.files.len <= bounds.include_files_max);
    assert(space.files[0].parent == source_space.no_file);
    var end: u32 = 0;
    for (space.files, 0..) |file, index| {
        assert(file.depth <= bounds.include_depth_max);
        assert(index == 0 or file.parent < index);
        assert(file.start >= end and file.start <= file.end);
        end = file.end;
        _ = space.location(file.end);
    }
    assert(end <= space.parsed.source.len);
    for (space.problems) |problem| assert(problem.offset <= space.parsed.source.len);
}

test "fuzz: INCLUDE discovery stays within its bounds" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try std.testing.fuzz(Context{ .directory = temporary.dir }, discover, .{ .corpus = &.{""} });
}
