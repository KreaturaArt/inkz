//! Plays a story on the new compiler and VM as the old e2e helpers played it on the old
//! pipeline: compiled from source (or from its file, so INCLUDEs resolve), and played with a
//! list of choices, choosing whenever it can't continue. Used by e2e_tests.zig.

const std = @import("std");
const assert = std.debug.assert;
const compile = @import("../compiler/compile.zig");
const vm = @import("../vm/api.zig");
const Severity = @import("../vm/state.zig").Diagnostic.Severity;

const steps_max = 100_000;

fn ignore_error(context: ?*anyopaque, message: []const u8, severity: Severity) void {
    assert(context == null);
    assert(message.len > 0 or severity == .warning);
}

/// Plays `source` through `choices` on the new VM (choosing when it can't continue, as the
/// old helpers do). Runtime errors don't stop it, as they don't on the old runtime.
pub fn play(
    gpa: std.mem.Allocator,
    source: []const u8,
    path: ?[]const u8,
    choices: []const usize,
) ![]u8 {
    assert(source.len < std.math.maxInt(u32));
    var program = if (path) |file| try compile_file(gpa, file) else try compile.compile_source(
        gpa,
        source,
    );
    defer program.deinit(gpa);
    var story: vm.Story = undefined;
    try story.init(gpa, &program, .{ .on_error = ignore_error });
    defer story.deinit(gpa);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);
    var chosen: usize = 0;
    for (0..steps_max) |_| {
        const waiting = story.current_choices_count() > 0 and !story.can_continue();
        if (waiting and chosen < choices.len) {
            try story.choose_choice_index(@intCast(choices[chosen]));
            chosen += 1;
            continue;
        }
        if (!story.can_continue()) break;
        const line = try story.cont_alloc(gpa);
        defer gpa.free(line);
        try output.appendSlice(gpa, line);
    }
    assert(chosen <= choices.len);
    return output.toOwnedSlice(gpa);
}

/// Compiles a fixture from its directory (so INCLUDEs resolve as in inklecate).
fn compile_file(gpa: std.mem.Allocator, path: []const u8) !@import("../core/program.zig").Program {
    assert(path.len > 0);
    assert(std.mem.endsWith(u8, path, ".ink"));
    const io = std.testing.io;
    assert(path.len < std.math.maxInt(u32));
    const directory_path = std.fs.path.dirname(path) orelse ".";
    var directory = try std.Io.Dir.cwd().openDir(io, directory_path, .{});
    defer directory.close(io);
    return compile.compile_file(gpa, io, directory, std.fs.path.basename(path));
}
