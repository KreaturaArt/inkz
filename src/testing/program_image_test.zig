//! The binary program image on real programs: every ground-truth case and
//! compiled sources write deterministically and load back to the same program; corrupted
//! images are rejected with named errors, never a crash.

const std = @import("std");
const assert = std.debug.assert;
const ink_json = @import("../core/ink_json.zig");
const program_image = @import("../core/program_image.zig");
const program_testing = @import("../core/program_testing.zig");
const Program = @import("../core/program.zig").Program;
const compile = @import("../compiler/compile.zig");
const cases = @import("cases.zig");

/// Writes `program`'s image, checks it's deterministic and loads back the same program.
fn round_trip(gpa: std.mem.Allocator, program: *const Program) !u64 {
    var first: std.Io.Writer.Allocating = .init(gpa);
    defer first.deinit();
    try program_image.write(program, &first.writer);
    var second: std.Io.Writer.Allocating = .init(gpa);
    defer second.deinit();
    try program_image.write(program, &second.writer);
    try std.testing.expectEqualSlices(u8, first.written(), second.written());
    try std.testing.expectEqual(program_image.image_bytes(program), first.written().len);
    var loaded = try program_image.load(gpa, first.written());
    defer loaded.deinit(gpa);
    try program_testing.expect_same_program(program, &loaded);
    return first.written().len;
}

test "every ground-truth case round-trips through an image" {
    // Each case's JSON loaded, written twice (same bytes) and
    // loaded from the image (the same program); the sizes are reported next to the JSON's.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var json_total: u64 = 0;
    var image_total: u64 = 0;
    var checked: u32 = 0;
    for (try cases.ids(arena, io)) |id| {
        const path = try std.fmt.allocPrint(arena, "{s}/{s}.ink.json", .{
            cases.cases_directory,
            id,
        });
        const json = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 << 20));
        var program = ink_json.load(std.testing.allocator, json) catch continue;
        defer program.deinit(std.testing.allocator);
        image_total += try round_trip(std.testing.allocator, &program);
        json_total += json.len;
        checked += 1;
    }
    try std.testing.expect(checked > 150);
    std.debug.print("program images: {d} cases, {d} bytes of images for {d} bytes of JSON\n", .{
        checked,
        image_total,
        json_total,
    });
}

test "compiled programs round-trip through an image" {
    // For the compiler's output: two whole stories compiled from source.
    const gpa = std.testing.allocator;
    const paths = [_][]const u8{
        "test/fixture/crime_scene.ink",
        "test/fixture/simple_taster_tutorial.ink",
    };
    for (paths) |path| {
        const limit: std.Io.Limit = .limited(1 << 20);
        const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, limit);
        defer gpa.free(source);
        var program = try compile.compile_source(gpa, source);
        defer program.deinit(gpa);
        _ = try round_trip(gpa, &program);
    }
}

/// Loads `bytes`; either it is a program that passes its check, or a named error.
fn load_or_reject(bytes: []const u8) bool {
    assert(bytes.len < 1 << 20);
    assert(@TypeOf(program_image.load) != void);
    var program = program_image.load(std.testing.allocator, bytes) catch return false;
    defer program.deinit(std.testing.allocator);
    assert(program.check() == .ok);
    return true;
}

test "corrupted images are rejected without crashing" {
    // The image loader's negative space: a small story's image truncated at every length,
    // and every byte set to 0x00, 0xff and itself plus one; each load either gives a valid
    // program or an error. The named errors for the header are checked directly.
    const gpa = std.testing.allocator;
    const source = "VAR x = 1\nHello {x}.\n* [A] -> k\n== k ==\nDone.\n-> END\n";
    var program = try compile.compile_source(gpa, source);
    defer program.deinit(gpa);
    var image: std.Io.Writer.Allocating = .init(gpa);
    defer image.deinit();
    try program_image.write(&program, &image.writer);
    const bytes = image.written();
    for (0..bytes.len) |length| try std.testing.expect(!load_or_reject(bytes[0..length]));
    const copy = try gpa.dupe(u8, bytes);
    defer gpa.free(copy);
    var accepted: u32 = 0;
    for (0..copy.len) |position| {
        const original = copy[position];
        for ([_]u8{ 0x00, 0xff, original +% 1 }) |value| {
            if (value == original) continue;
            copy[position] = value;
            accepted += @intFromBool(load_or_reject(copy));
        }
        copy[position] = original;
    }
    try std.testing.expect(accepted < copy.len);
    copy[0] = 'X';
    try std.testing.expectError(error.NotAProgramImage, program_image.load(gpa, copy));
    copy[0] = bytes[0];
    copy[8] = 99;
    try std.testing.expectError(error.UnsupportedFormatVersion, program_image.load(gpa, copy));
}
