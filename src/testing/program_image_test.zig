//! The binary program image on real programs: every ground-truth case and
//! compiled sources write deterministically and load back to the same program; corrupted
//! images are rejected with named errors, never a crash.

const std = @import("std");
const assert = std.debug.assert;
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
    var programs: cases.Programs = try .init(arena, std.testing.allocator, io);
    while (try programs.next()) |case| {
        var program = case.program;
        defer program.deinit(std.testing.allocator);
        image_total += try round_trip(std.testing.allocator, &program);
        json_total += case.json.len;
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

const ProgramBuilder = @import("../core/program_builder.zig").ProgramBuilder;
const ListOrigin = @import("../core/program.zig").ListOrigin;
const Opcode = @import("../core/instruction.zig").Opcode;

/// A root with a list literal of two items, a variable pointer `x` (context 0), a plain
/// divert to the knot `k` and a text, over the lists `letters = a, b` and an empty `none`.
fn build_records(gpa: std.mem.Allocator) !Program {
    var builder = try ProgramBuilder.init(gpa);
    defer builder.deinit();
    _ = try builder.begin_container(.{});
    try builder.add_list_literal(&.{ "letters.a", "letters.b" }, &.{});
    try builder.add_variable_pointer("x", 0);
    try builder.add_divert("k", .{ .kind = .plain, .conditional = false, .variable = false });
    try builder.add(.text, try builder.intern("A"));
    _ = try builder.list_origin("letters", &.{
        .{ .name = "a", .value = 1 },
        .{ .name = "b", .value = 2 },
    });
    _ = try builder.list_origin("none", &.{});
    _ = try builder.begin_container(.{ .name = "k", .named_only = true });
    try builder.add(.done, {});
    try builder.end_container();
    try builder.end_container();
    return builder.finish();
}

/// The extra index of the record behind the first instruction with `opcode`.
fn record_at(program: *const Program, opcode: Opcode) u32 {
    const opcodes = program.instructions.items(.opcode);
    const position = std.mem.indexOfScalar(Opcode, opcodes, opcode).?;
    return program.instructions.items(.operand)[position];
}

/// Expects `program` to fail its check with `fault` and its image to be rejected on load.
fn expect_rejected(program: *const Program, fault: Program.Fault) !void {
    const gpa = std.testing.allocator;
    if (fault != .ok) try std.testing.expectEqual(fault, program.check());
    var image: std.Io.Writer.Allocating = .init(gpa);
    defer image.deinit();
    try program_image.write(program, &image.writer);
    try std.testing.expectError(error.InvalidImage, program_image.load(gpa, image.written()));
}

test "an image's list literals are checked word by word" {
    // The VM slices a list literal's tail and stores its indices unchecked, so loading
    // checks the header's counts and every item and origin index. Corrupt one or two words
    // at a time, expect the named fault and a rejected image, then restore them.
    const gpa = std.testing.allocator;
    var program = try build_records(gpa);
    defer program.deinit(gpa);
    try std.testing.expectEqual(Program.Fault.ok, program.check());
    const extra: []u32 = @constCast(program.extra);
    const list = record_at(&program, .list);
    const saved: [4]u32 = extra[list..][0..4].*;
    extra[list] = std.math.maxInt(u32);
    try expect_rejected(&program, .extra_out_of_range);
    extra[list] = saved[0];
    extra[list + 1] = std.math.maxInt(u32);
    try expect_rejected(&program, .extra_out_of_range);
    extra[list + 1] = saved[1];
    extra[list + 3] = 2;
    try expect_rejected(&program, .list_item_out_of_range);
    extra[list + 3] = saved[3];
    // One item and one origin: the second word is read as origin 7, which doesn't exist.
    extra[list] = 1;
    extra[list + 1] = 1;
    extra[list + 3] = 7;
    try expect_rejected(&program, .list_origin_out_of_range);
    @memcpy(extra[list..][0..4], &saved);
    try std.testing.expectEqual(Program.Fault.ok, program.check());
}

test "an image's variable pointers, divert kinds and newline are checked" {
    // A variable pointer's name must be a string and its context at least -1; a divert's
    // kind must be one of three in its two bits; the newline string must be "\n". Corrupt
    // each, expect a rejected image, restore it; the untouched image loads.
    const gpa = std.testing.allocator;
    var program = try build_records(gpa);
    defer program.deinit(gpa);
    const extra: []u32 = @constCast(program.extra);
    const pointer = record_at(&program, .variable_pointer);
    const name = extra[pointer];
    extra[pointer] = 9999;
    try expect_rejected(&program, .string_out_of_range);
    extra[pointer] = name;
    extra[pointer + 1] = @bitCast(@as(i32, -2));
    try expect_rejected(&program, .variable_pointer_context_out_of_range);
    extra[pointer + 1] = @bitCast(@as(i32, -1));
    try std.testing.expectEqual(Program.Fault.ok, program.check());
    const flags_at = record_at(&program, .divert) + 3;
    const flags = extra[flags_at];
    extra[flags_at] = flags | 0b11;
    try expect_rejected(&program, .extra_out_of_range);
    extra[flags_at] = flags;
    const newline = program.newline;
    program.newline = program.strings.find("A").?;
    try expect_rejected(&program, .ok);
    program.newline = newline;
    var image: std.Io.Writer.Allocating = .init(gpa);
    defer image.deinit();
    try program_image.write(&program, &image.writer);
    var loaded = try program_image.load(gpa, image.written());
    loaded.deinit(gpa);
}

test "list origin item counts that overflow u32 are rejected" {
    // check_tables sums the origins' item counts: an empty second origin claiming the
    // largest u32 count sums past u32, which must be a fault and a rejected image.
    const gpa = std.testing.allocator;
    var program = try build_records(gpa);
    defer program.deinit(gpa);
    const origins: []ListOrigin = @constCast(program.list_origins);
    origins[1].items_count = std.math.maxInt(u32);
    try expect_rejected(&program, .list_items_not_partitioned);
}

test "a trusted load gives the same program as a checked one" {
    // Every ground-truth case's image, loaded both ways (P16.19, F17).
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var loaded_count: u32 = 0;
    var programs: cases.Programs = try .init(arena, arena, io);
    while (try programs.next()) |case| {
        var image: std.Io.Writer.Allocating = .init(arena);
        try program_image.write(&case.program, &image.writer);
        var checked = try program_image.load(arena, image.written());
        var trusted = try program_image.load_trusted(arena, image.written());
        try program_testing.expect_same_program(&checked, &trusted);
        loaded_count += 1;
    }
    try std.testing.expect(loaded_count > 150);
}

test "a trusted load still rejects a wrong header and section layout" {
    // The same named errors as `load`: magic, format version, endianness, the section count
    // and a section's element size.
    const gpa = std.testing.allocator;
    var program = try compile.compile_source(gpa, "VAR x = 1\nHello {x}.\n-> END\n");
    defer program.deinit(gpa);
    var image: std.Io.Writer.Allocating = .init(gpa);
    defer image.deinit();
    try program_image.write(&program, &image.writer);
    const Corruption = struct { at: u32, value: u8, expected: program_image.Error };
    const corruptions = [_]Corruption{
        .{ .at = 0, .value = 'X', .expected = error.NotAProgramImage },
        .{ .at = 8, .value = 99, .expected = error.UnsupportedFormatVersion },
        .{ .at = 12, .value = 0x55, .expected = error.UnsupportedEndianness },
        .{ .at = 32, .value = 3, .expected = error.SectionLayoutMismatch },
        .{ .at = 40, .value = 7, .expected = error.SectionLayoutMismatch },
    };
    for (corruptions) |corruption| {
        const copy = try gpa.dupe(u8, image.written());
        defer gpa.free(copy);
        copy[corruption.at] = corruption.value;
        try std.testing.expectError(corruption.expected, program_image.load(gpa, copy));
        try std.testing.expectError(corruption.expected, program_image.load_trusted(gpa, copy));
    }
    try std.testing.expectError(
        error.ImageTruncated,
        program_image.load_trusted(gpa, image.written()[0 .. image.written().len - 4]),
    );
}
