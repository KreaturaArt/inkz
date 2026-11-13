//! Shared by the runtime's fuzz targets (plan P11.8–P11.10): a generated story compiled into
//! a program, a story on it whose errors go to a handler, and play with fuzzer-picked
//! choices.

const std = @import("std");
const assert = std.debug.assert;
const compile = @import("../compiler/compile.zig");
const Program = @import("../core/program.zig").Program;
const api = @import("../runtime/api.zig");
const fuzz_ink = @import("../testing/fuzz_ink.zig");

pub const Story = api.Story;
pub const Value = api.Value;
const CoreStory = @import("../runtime/story.zig").Story;
const Allocator = std.mem.Allocator;

/// Steps (lines and choices) one play may take: generated stories loop.
pub const steps_max = 256;
const steps_per_continue_max = 10_000;

/// The program of a generated story, or null when it doesn't compile.
pub fn compile_story(gpa: Allocator, choices: fuzz_ink.Choices, buffer: []u8) !?Program {
    assert(buffer.len == fuzz_ink.source_bytes_max);
    const source = fuzz_ink.Generator.generate(choices, buffer, .{});
    assert(source.len <= buffer.len);
    return compile.compile_source(gpa, source) catch |err| switch (err) {
        error.CompileFailed, error.ParseFailed, error.WorkspaceFull => null,
        else => err,
    };
}

/// Runtime errors are part of play: generated stories divide by zero, mix types, and run
/// out of content.
fn ignore_error(context: ?*anyopaque, message: []const u8, severity: api.Severity) void {
    assert(context == null);
    assert(message.len > 0);
    _ = severity;
}

/// The external `e0(x)`: returns its argument.
fn echo(context: ?*anyopaque, story: *CoreStory, arguments: []const Value) anyerror!Value {
    assert(context == null);
    assert(story.state.memory.len > 0);
    return if (arguments.len > 0) arguments[0] else .null;
}

/// How a story is set up; a save doesn't hold it, so a story loading one needs the same.
pub const Setup = struct {
    random_seed: i32,
    fallbacks: bool,
    bind_external: bool,

    /// The fuzzer picks the seed, the fallback rule and whether `e0` is bound.
    pub fn pick(choices: fuzz_ink.Choices) Setup {
        const setup: Setup = .{
            .random_seed = choices.choose(i32),
            .fallbacks = choices.choose(bool),
            .bind_external = choices.choose(bool),
        };
        assert(@sizeOf(Setup) <= 8);
        return setup;
    }
};

pub fn init_story(story: *Story, gpa: Allocator, program: *const Program, setup: Setup) !void {
    assert(program.check() == .ok);
    try story.init(gpa, program, .{
        // Generated stories loop; a small step budget keeps each input fast.
        .limits = .{ .steps_per_continue_max = steps_per_continue_max },
        .random_seed = setup.random_seed,
        .allow_external_function_fallbacks = setup.fallbacks,
        .on_error = ignore_error,
    });
    if (setup.bind_external) try story.bind_external_function("e0", .{}, null, echo);
    assert(story.core.state.check() == .ok);
}

/// Continues and chooses until the story ends, `steps` run out, or a call fails; the state
/// checks after every call that returns. False when a call failed (a limit or host error,
/// ink's exceptions); the story is then back at its last line or has failed closed.
pub fn play(story: *Story, choices: fuzz_ink.Choices, steps: u32) bool {
    assert(steps <= steps_max);
    var taken: u32 = 0;
    while (taken < steps) : (taken += 1) {
        if (story.can_continue()) {
            _ = story.cont() catch return false;
        } else {
            const count = story.current_choices_count();
            if (count == 0) return true;
            story.choose_choice_index(@intCast(choices.below(count))) catch return false;
        }
        assert(story.core.state.check() == .ok);
    }
    assert(taken == steps);
    return true;
}
