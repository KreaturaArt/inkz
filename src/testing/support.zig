//! Shared by the tests, benchmarks and fuzz targets: compiling a fixture from its own
//! directory, playing a program through a list of choices, and callbacks that do nothing.

const std = @import("std");
const compile = @import("../compiler/compile.zig");
const Program = @import("../core/program.zig").Program;
const api = @import("../runtime/api.zig");
const story_module = @import("../runtime/story.zig");
const HostValue = story_module.HostValue;
const Severity = @import("../runtime/state.zig").Diagnostic.Severity;

/// An error handler that drops the story's errors and warnings.
pub fn ignore_message(_: ?*anyopaque, _: []const u8, _: Severity) void {}

/// An external function that returns 1.
pub fn noop_external(
    _: ?*anyopaque,
    _: *story_module.Story,
    _: []const HostValue,
) anyerror!HostValue {
    return .{ .integer = 1 };
}

/// Binds every external to `noop_external` and drops the story's messages, so any story
/// plays without a host.
pub fn quiet(story: *story_module.Story) void {
    for (story.program.externals) |external| {
        const name = story.program.strings.get(external.name);
        story.bind_external_function(name, noop_external, null, true) catch {};
    }
    story.on_error = ignore_message;
}

/// Compiles the `.ink` file at `path` from its own directory, so INCLUDEs resolve as in
/// inklecate.
pub fn compile_fixture(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Program {
    const directory_path = std.fs.path.dirname(path) orelse ".";
    var directory = try std.Io.Dir.cwd().openDir(io, directory_path, .{});
    defer directory.close(io);
    return compile.compile_file(gpa, io, directory, std.fs.path.basename(path));
}

pub const Played = struct {
    output: []u8,
    /// The choices offered when the story stopped.
    choices_count: u32,
};

/// Plays `program`, taking the next of `choices` whenever the story waits at a choice, until
/// it can't continue and no choice is left to take. Runtime errors don't stop it.
pub fn play(gpa: std.mem.Allocator, program: *const Program, choices: []const u32) !Played {
    const steps_max = 100_000;
    var story: api.Story = undefined;
    try story.init(gpa, program, .{ .on_error = ignore_message });
    defer story.deinit(gpa);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);
    var chosen: usize = 0;
    for (0..steps_max) |_| {
        const waiting = story.current_choices_count() > 0 and !story.can_continue();
        if (waiting and chosen < choices.len) {
            try story.choose_choice_index(choices[chosen]);
            chosen += 1;
            continue;
        }
        if (!story.can_continue()) break;
        const line = try story.cont_alloc(gpa);
        defer gpa.free(line);
        try output.appendSlice(gpa, line);
    }
    const choices_count = story.current_choices_count();
    return .{ .output = try output.toOwnedSlice(gpa), .choices_count = choices_count };
}
