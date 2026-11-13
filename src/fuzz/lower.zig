//! Fuzz target for lowering and emission, and the JSON serializer (plan P11.6): generated
//! ink through the whole compiler. A compiled program passes Program.check, compiling is
//! deterministic, and its JSON loads back into the same program (compared as images).

const std = @import("std");
const assert = std.debug.assert;
const Smith = std.testing.Smith;
const compile = @import("../compiler/compile.zig");
const ink_json = @import("../core/ink_json.zig");
const program_image = @import("../core/program_image.zig");
const Program = @import("../core/program.zig").Program;
const fuzz_ink = @import("../testing/fuzz_ink.zig");

const Allocator = std.mem.Allocator;

fn lower_emit(_: void, smith: *Smith) anyerror!void {
    var buffer: [fuzz_ink.source_bytes_max]u8 = undefined;
    const choices: fuzz_ink.Choices = .{ .smith = smith };
    const source = fuzz_ink.Generator.generate(choices, &buffer, .{});
    _ = try check_source(source);
}

fn image_of(gpa: Allocator, program: *const Program) ![]u8 {
    assert(program.check() == .ok);
    var image: std.Io.Writer.Allocating = .init(gpa);
    errdefer image.deinit();
    try program_image.write(program, &image.writer);
    assert(image.written().len == program_image.image_bytes(program));
    return image.toOwnedSlice();
}

/// Compiles `source` twice and through JSON; whether it compiled.
fn check_source(source: []const u8) !bool {
    assert(source.len <= fuzz_ink.source_bytes_max);
    const gpa = std.testing.allocator;
    var program = compile.compile_source(gpa, source) catch |err| switch (err) {
        error.CompileFailed, error.ParseFailed, error.WorkspaceFull => return false,
        else => return err,
    };
    defer program.deinit(gpa);
    assert(program.check() == .ok);
    const image = try image_of(gpa, &program);
    defer gpa.free(image);

    var again = try compile.compile_source(gpa, source);
    defer again.deinit(gpa);
    const image_again = try image_of(gpa, &again);
    defer gpa.free(image_again);
    assert(std.mem.eql(u8, image, image_again));

    var json: std.Io.Writer.Allocating = .init(gpa);
    defer json.deinit();
    try ink_json.serialize(gpa, &program, &json.writer);
    var loaded = try ink_json.load(gpa, json.written());
    defer loaded.deinit(gpa);
    const image_loaded = try image_of(gpa, &loaded);
    defer gpa.free(image_loaded);
    assert(std.mem.eql(u8, image, image_loaded));
    return true;
}

test "fuzz: compiled programs check, repeat, and survive their JSON" {
    // Seeded sources first: most compile, and every compiled one passes the checks.
    var buffer: [fuzz_ink.source_bytes_max]u8 = undefined;
    var compiled: u32 = 0;
    for (0..32) |seed| {
        const source = fuzz_ink.generate_seeded(seed, &buffer, .{});
        if (try check_source(source)) compiled += 1;
    }
    try std.testing.expect(compiled > 16);
    try std.testing.fuzz({}, lower_emit, .{ .corpus = &.{""} });
}
