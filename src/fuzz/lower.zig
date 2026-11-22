//! Fuzz target for lowering and emission, and the JSON serializer: generated
//! ink through the whole compiler. A compiled program passes Program.check, compiling is
//! deterministic, and its JSON loads back into the same program (compared as images).

const std = @import("std");
const assert = std.debug.assert;
const compile = @import("../compiler/compile.zig");
const messages = @import("../compiler/messages.zig");
const ink_json = @import("../core/ink_json.zig");
const program_image = @import("../core/program_image.zig");
const Program = @import("../core/program.zig").Program;
const fuzz_ink = @import("../testing/fuzz_ink.zig");

const Allocator = std.mem.Allocator;

/// A generated source compiled and checked; whether it compiled.
fn lower_emit(choices: fuzz_ink.Choices) !bool {
    var buffer: [fuzz_ink.source_bytes_max]u8 = undefined;
    const source = fuzz_ink.Generator.generate(choices, &buffer, .{});
    return check_source(source);
}

fn image_of(gpa: Allocator, program: *const Program) ![]u8 {
    assert(program.check() == .ok);
    var image: std.Io.Writer.Allocating = .init(gpa);
    errdefer image.deinit();
    try program_image.write(program, &image.writer);
    assert(image.written().len == program_image.image_bytes(program));
    return image.toOwnedSlice();
}

/// Counts the errors a compile delivers.
const Errors = struct {
    count: u32 = 0,

    fn add(context: ?*anyopaque, diagnostic: messages.Diagnostic) void {
        assert(diagnostic.line > 0 and diagnostic.message.len > 0);
        const errors: *Errors = @ptrCast(@alignCast(context.?));
        if (diagnostic.severity == .@"error") errors.count += 1;
    }
};

/// A story that fails to compile does so with diagnostics too, and says why: at least one
/// error. With a sink, lowering runs even after reference errors, for its own
/// diagnostics (as ink generates before it resolves), so this lowers broken stories.
pub fn check_failure(source: []const u8) !void {
    assert(source.len <= fuzz_ink.source_bytes_max);
    const gpa = std.testing.allocator;
    var errors: Errors = .{};
    const sink: messages.Sink = .{ .context = &errors, .function = Errors.add };
    var program = compile.compile_source_with(gpa, source, .{ .diagnostics = sink }) catch |err|
        switch (err) {
            error.CompileFailed => {
                assert(errors.count > 0);
                return;
            },
            else => return err,
        };
    program.deinit(gpa);
    unreachable; // It failed without a sink.
}

/// Compiles `source` twice and through JSON; whether it compiled.
fn check_source(source: []const u8) !bool {
    assert(source.len <= fuzz_ink.source_bytes_max);
    const gpa = std.testing.allocator;
    var program = compile.compile_source(gpa, source) catch |err| switch (err) {
        error.CompileFailed => {
            try check_failure(source);
            return false;
        },
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
    try fuzz_ink.run_target(lower_emit, 16);
}
