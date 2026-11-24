//! Shared by the runtime's fuzz targets and the swarm's play (`zig build swarm`): a
//! generated story compiled into a program, a story on it whose errors go to a handler, and
//! play with fuzzer-picked choices.

const std = @import("std");
const assert = std.debug.assert;
const compile = @import("../compiler/compile.zig");
const Program = @import("../core/program.zig").Program;
const api = @import("../runtime/story.zig");
const fuzz_ink = @import("../testing/fuzz_ink.zig");
const support = @import("../testing/support.zig");

pub const Story = api.Story;
pub const Value = api.Value;
pub const BindOptions = api.BindOptions;
const Allocator = std.mem.Allocator;
const Limits = @import("../core/limits.zig").Limits;

/// Steps (lines and choices) one play may take: generated stories loop.
pub const steps_max = 256;
pub const steps_per_continue_max = 10_000;

/// The program of a generated story, or null when it doesn't compile.
pub fn compile_story(gpa: Allocator, choices: fuzz_ink.Choices, buffer: []u8) !?Program {
    assert(buffer.len == fuzz_ink.source_bytes_max);
    const source = fuzz_ink.Generator.generate(choices, buffer, .{});
    assert(source.len <= buffer.len);
    return compile.compile_source(gpa, source) catch |err| switch (err) {
        error.CompileFailed => null,
        else => err,
    };
}

/// The external `e0(x)`: returns its argument.
pub fn echo(context: ?*anyopaque, _: *Story, arguments: []const Value) anyerror!Value {
    assert(context == null);
    return if (arguments.len > 0) arguments[0] else .null;
}

/// What `evaluating_echo` evaluates: knots with parameters among them, so an evaluation
/// with fewer arguments than parameters runs with the external's own just below its frame.
const evaluated = [_][]const u8{ "tunnel1", "thread1", "jump1", "k0", "f0", "f1" };

/// `e0(x)` as a host that calls back in: evaluates one of `evaluated` with no arguments
/// (picked by an integer `x`), ignores how that went, and returns its argument.
fn evaluating_echo(context: ?*anyopaque, story: *Story, arguments: []const Value) anyerror!Value {
    assert(context == null);
    const echoed: Value = if (arguments.len > 0) arguments[0] else .null;
    const at: u32 = if (echoed == .integer) @truncate(@abs(echoed.integer)) else 0;
    var text: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&text);
    _ = story.evaluate_function(evaluated[at % evaluated.len], &.{}, &writer) catch {};
    return echoed;
}

/// How a story is set up; a save doesn't hold it, so a story loading one needs the same.
pub const Setup = struct {
    random_seed: i32,
    fallbacks: bool,
    /// Every external the story declares is bound: `e0` in generated stories, any name in
    /// the swarm's mutated ground-truth stories.
    bind_external: bool,
    /// `e0`, when bound, is `evaluating_echo` (the swarm's host target).
    evaluate_in_external: bool = false,
    /// `e0`, when bound, isn't lookahead-safe (the swarm's host target): ink's error when
    /// string evaluation (a choice's text) calls it, and a line that ends before the call.
    lookahead_unsafe: bool = false,

    /// The fuzzer picks the seed, the fallback rule and whether `e0` is bound.
    pub fn pick(choices: fuzz_ink.Choices) Setup {
        const setup: Setup = .{
            .random_seed = choices.choose(i32),
            .fallbacks = choices.choose(bool),
            .bind_external = choices.choose(bool),
        };
        assert(@sizeOf(Setup) <= 12);
        return setup;
    }
};

/// Generated stories loop; a small step budget keeps each input fast.
const limits_default: Limits = .{ .steps_per_continue_max = steps_per_continue_max };

pub fn init_story(story: *Story, gpa: Allocator, program: *const Program, setup: Setup) !void {
    return init_story_with(story, gpa, program, setup, limits_default);
}

/// `init_story` from the program's ink JSON (`Story.init_from_json`, which owns the program
/// it loads).
pub fn init_story_from_json(story: *Story, gpa: Allocator, json: []const u8, setup: Setup) !void {
    assert(json.len > 0);
    try story.init_from_json(gpa, json, options_of(setup, limits_default));
    try bind_externals(story, setup);
    assert(story.state.check() == .ok);
}

pub fn init_story_with(
    story: *Story,
    gpa: Allocator,
    program: *const Program,
    setup: Setup,
    limits: Limits,
) !void {
    assert(program.check() == .ok);
    assert(limits.check() == .ok);
    try story.init(gpa, program, options_of(setup, limits));
    try bind_externals(story, setup);
    assert(story.state.check() == .ok);
}

fn options_of(setup: Setup, limits: Limits) Story.Options {
    assert(limits.check() == .ok);
    return .{
        .limits = limits,
        .random_seed = setup.random_seed,
        .allow_external_function_fallbacks = setup.fallbacks,
        // Runtime errors are part of play: generated stories divide by zero, mix types,
        // and run out of content.
        .on_error = support.ignore_message,
    };
}

fn bind_externals(story: *Story, setup: Setup) !void {
    if (!setup.bind_external) return;
    const function = if (setup.evaluate_in_external) &evaluating_echo else &echo;
    const program = story.program;
    for (program.externals) |external| {
        const name = program.strings.get(external.name);
        const options: BindOptions = .{ .lookahead_safe = !setup.lookahead_unsafe };
        try story.bind_external_function(name, options, null, function);
    }
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
        assert(story.state.check() == .ok);
    }
    assert(taken == steps);
    return true;
}

/// Whether `save` may hold a float that doesn't load back as it was: ink's save writes an
/// infinity as ±3.4E+38 and NaN as 0.0 (SimpleJson's Write(float)), so the loaded story
/// shows `-3.4E+38` where the saved one showed `-Infinity`. A real 0.0 reads the same as NaN,
/// so a save with any 0.0 counts.
pub fn save_loses_floats(gpa: Allocator, save: []const u8) !bool {
    var scanner: std.json.Scanner = .initCompleteInput(gpa, save);
    defer scanner.deinit();
    while (true) switch (try scanner.next()) {
        .number => |text| for ([_][]const u8{ "3.4E+38", "-3.4E+38", "0.0" }) |stand_in| {
            if (std.mem.eql(u8, text, stand_in)) return true;
        },
        .end_of_document => return false,
        else => {},
    };
}

test "fuzz: a save with an infinity or NaN loses floats" {
    const gpa = std.testing.allocator;
    var program = try compile.compile_source(gpa,
        \\VAR low = 1.0
        \\~ low = -1.0 / 0.0
        \\Hi
        \\* [Go]
        \\  {low}
        \\-> END
    );
    defer program.deinit(gpa);
    var story: Story = undefined;
    try story.init(gpa, &program, .{});
    defer story.deinit(gpa);
    _ = try story.cont();
    var save: std.Io.Writer.Allocating = .init(gpa);
    defer save.deinit();
    try story.to_json(&save.writer);
    try std.testing.expect(try save_loses_floats(gpa, save.written()));

    // The loaded story shows ink's stand-in, as ink does.
    var loaded: Story = undefined;
    try loaded.init(gpa, &program, .{});
    defer loaded.deinit(gpa);
    try loaded.load_json(save.written());
    try loaded.choose_choice_index(0);
    try std.testing.expectEqualStrings("-3.4E+38\n", (try loaded.cont()).get());

    try std.testing.expect(try save_loses_floats(gpa, "{\"a\":[0.0]}"));
    try std.testing.expect(!try save_loses_floats(gpa, "{\"a\":[1.5,3,-2.0,\"0.0\"]}"));
}
