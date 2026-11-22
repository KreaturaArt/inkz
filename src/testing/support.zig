//! Shared by the tests, benchmarks and fuzz targets: compiling a fixture from its own
//! directory, starting a story, playing it by a choice policy, and callbacks that do nothing.

const std = @import("std");
const assert = std.debug.assert;
const compile = @import("../compiler/compile.zig");
const Program = @import("../core/program.zig").Program;
const api = @import("../runtime/api.zig");
const story_module = @import("../runtime/story.zig");
const HostValue = story_module.HostValue;
const DotnetRandom = @import("../core/dotnet_random.zig").DotnetRandom;
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

/// A story on `program` with `limits`, owned by the caller; `stop` frees it.
pub fn start(gpa: std.mem.Allocator, program: *const Program, limits: api.Limits) !*api.Story {
    assert(program.containers.len > 0);
    const story = try gpa.create(api.Story);
    errdefer gpa.destroy(story);
    try story.init(gpa, program, .{ .limits = limits });
    return story;
}

pub fn stop(gpa: std.mem.Allocator, story: *api.Story) void {
    story.deinit(gpa);
    gpa.destroy(story);
}

/// Which choice `play` takes at each turn.
pub const Policy = union(enum) {
    first,
    last,
    /// `Next() % count` of .NET's `new Random(seed)`, as ink's harness picks.
    seeded: i32,
    /// These choices in order; play stops at the first choice past the list, so an empty
    /// list plays to the first choice.
    list: []const u32,
};

/// The longest play, in turns (choices taken), and in lines.
pub const turns_max = 200;
pub const lines_max = 100_000;

pub const Played = struct {
    turns: u32 = 0,
    lines: u32 = 0,
    /// The choices offered when the story stopped.
    choices_count: u32 = 0,
};

/// Plays `story` from where it stands: writes every line to `output` (when given), then
/// takes a choice by `policy`, until no choice is offered, the policy has none left or
/// `turns_max` turns have passed. Runtime errors go to the story's handler.
pub fn play(story: *api.Story, policy: Policy, output: ?*std.Io.Writer) !Played {
    var random: DotnetRandom = .init(if (policy == .seeded) policy.seeded else 0);
    var played: Played = .{};
    while (true) : (played.turns += 1) {
        while (story.can_continue()) : (played.lines += 1) {
            if (played.lines == lines_max) return error.LineLimit;
            const line = (try story.cont()).get();
            if (output) |writer| try writer.writeAll(line);
        }
        played.choices_count = story.current_choices_count();
        const count = played.choices_count;
        if (count == 0 or played.turns == turns_max) return played;
        const index: u32 = switch (policy) {
            .first => 0,
            .last => count - 1,
            .seeded => @intCast(@mod(random.next(), @as(i32, @intCast(count)))),
            .list => |choices| if (played.turns < choices.len) choices[played.turns] else {
                return played;
            },
        };
        try story.choose_choice_index(index);
    }
}

/// `play`, with the output in memory the caller owns.
pub fn play_alloc(gpa: std.mem.Allocator, story: *api.Story, policy: Policy) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(gpa);
    errdefer output.deinit();
    _ = try play(story, policy, &output.writer);
    return output.toOwnedSlice();
}

pub const PlayedProgram = struct { output: []u8, choices_count: u32 };

/// Plays `program` through `choices` (`Policy.list`) on a story whose errors go nowhere;
/// the output is the caller's.
pub fn play_program(
    gpa: std.mem.Allocator,
    program: *const Program,
    choices: []const u32,
) !PlayedProgram {
    var story: api.Story = undefined;
    try story.init(gpa, program, .{ .on_error = ignore_message });
    defer story.deinit(gpa);
    const output = try play_alloc(gpa, &story, .{ .list = choices });
    return .{ .output = output, .choices_count = story.current_choices_count() };
}

const policy_source =
    \\Start
    \\* A
    \\* B
    \\- Mid
    \\* C
    \\* D
    \\- End
    \\-> END
    \\
;

fn expect_play(policy: Policy, expected: []const u8, expected_played: Played) !void {
    const gpa = std.testing.allocator;
    var program = try compile.compile_source(gpa, policy_source);
    defer program.deinit(gpa);
    const story = try start(gpa, &program, .{});
    defer stop(gpa, story);
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    const played = try play(story, policy, &output.writer);
    try std.testing.expectEqualStrings(expected, output.written());
    try std.testing.expectEqual(expected_played, played);
}

test "play takes the first, the last or the listed choices" {
    // Two turns of two choices each.
    try expect_play(.first, "Start\nA\nMid\nC\nEnd\n", .{ .turns = 2, .lines = 5 });
    try expect_play(.last, "Start\nB\nMid\nD\nEnd\n", .{ .turns = 2, .lines = 5 });
    try expect_play(.{ .list = &.{ 1, 0 } }, "Start\nB\nMid\nC\nEnd\n", .{
        .turns = 2,
        .lines = 5,
    });
    // A list stops at the first choice past it, with that turn's choices offered.
    try expect_play(.{ .list = &.{1} }, "Start\nB\nMid\n", .{
        .turns = 1,
        .lines = 3,
        .choices_count = 2,
    });
    try expect_play(.{ .list = &.{} }, "Start\n", .{ .lines = 1, .choices_count = 2 });
}
