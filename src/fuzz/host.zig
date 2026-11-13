//! Fuzz target for the host API: on a generated story, a fuzzer-chosen sequence
//! of the calls a host makes, with names and values from the story's pool and outside it.
//! Every call returns a result or an error, and the state checks after each one.

const std = @import("std");
const assert = std.debug.assert;
const Smith = std.testing.Smith;
const fuzz_ink = @import("../testing/fuzz_ink.zig");
const play = @import("play.zig");

const Value = play.Value;
const calls_max = 48;

const Call = enum {
    cont,
    choose,
    choose_path,
    set_variable,
    get_variable,
    evaluate,
    switch_flow,
    default_flow,
    remove_flow,
    reset,
    visit_count,
    current_tags,
    global_tags,
    path_tags,
    current_text,
    flow_names,
    save_and_load,
};

const paths = [_][]const u8{ "k0", "k1", "k2", "k0.s0", "f0", "e0", "k0.s1", "missing", "0" };
const variables = [_][]const u8{ "v0", "v1", "v2", "c0", "l0", "missing" };
const functions = [_][]const u8{ "f0", "f1", "e0", "k0", "missing" };
const flows = [_][]const u8{ "DEFAULT_FLOW", "one", "two" };

const Sink = struct {
    count: u32 = 0,

    pub fn tag(sink: *Sink, text: []const u8) !void {
        assert(text.len < 1 << 20);
        assert(sink.count < std.math.maxInt(u32));
        sink.count += 1;
    }

    pub fn name(sink: *Sink, text: []const u8) !void {
        assert(text.len > 0);
        assert(sink.count < std.math.maxInt(u32));
        sink.count += 1;
    }
};

fn pick(choices: fuzz_ink.Choices, comptime list: []const []const u8) []const u8 {
    assert(list.len > 0);
    assert(list.len < 16);
    return list[choices.below(list.len)];
}

fn value(choices: fuzz_ink.Choices, kept: ?Value) Value {
    assert(@sizeOf(Value) <= 24);
    return switch (choices.choose(u3)) {
        0 => .null,
        1, 2 => .{ .integer = choices.choose(i32) },
        3 => .{ .float = @floatFromInt(choices.choose(i16)) },
        4 => .{ .bool = choices.choose(bool) },
        5 => .{ .string = "host" },
        6, 7 => kept orelse .null,
    };
}

/// One host call. `kept` is the last divert target read, so one goes back in (strings and
/// lists are views, valid only until the next mutating call).
fn call(story: *play.Story, choices: fuzz_ink.Choices, kept: *?Value) !void {
    assert(story.core.state.check() == .ok);
    var sink: Sink = .{};
    var text: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&text);
    switch (choices.choose(Call)) {
        .cont => if (story.can_continue()) {
            _ = try story.cont();
        },
        .choose => {
            const count = story.current_choices_count();
            try story.choose_choice_index(@intCast(choices.below(count + 1)));
        },
        .choose_path => {
            const arguments = [_]Value{value(choices, kept.*)};
            const count = choices.below(2);
            try story.choose_path_string(pick(choices, &paths), .{
                .reset_callstack = choices.choose(bool),
                .arguments = arguments[0..count],
            });
        },
        .set_variable => try story.set_variable(pick(choices, &variables), value(choices, kept.*)),
        .get_variable => if (story.get_variable(pick(choices, &variables))) |view| {
            const got = view.get();
            if (got == .divert_target) kept.* = got;
        },
        .evaluate => {
            const arguments = [_]Value{ value(choices, kept.*), value(choices, kept.*) };
            const count = choices.below(3);
            const name = pick(choices, &functions);
            const result = try story.evaluate_function(name, arguments[0..count], &writer);
            if (result.get() == .divert_target) kept.* = result.get();
        },
        .switch_flow => try story.switch_flow(pick(choices, &flows)),
        .default_flow => try story.switch_to_default_flow(),
        .remove_flow => try story.remove_flow(pick(choices, &flows)),
        .reset => try story.reset_state(),
        .visit_count => _ = story.visit_count_at_path_string(pick(choices, &paths)),
        .current_tags => try story.current_tags(&sink),
        .global_tags => try story.global_tags(&sink),
        .path_tags => try story.tags_for_content_at_path(pick(choices, &paths), &sink),
        .current_text => _ = try story.current_text(),
        .flow_names => try story.alive_flow_names(&sink),
        .save_and_load => try save_and_load(story),
    }
    assert(writer.end <= text.len);
    assert(story.core.state.check() == .ok);
}

/// A save loaded back into the story it came from.
fn save_and_load(story: *play.Story) !void {
    assert(story.core.state.check() == .ok);
    const gpa = std.testing.allocator;
    var save: std.Io.Writer.Allocating = .init(gpa);
    defer save.deinit();
    try story.to_json(&save.writer);
    assert(save.written().len > 0);
    try story.load_json(save.written());
    assert(story.core.state.check() == .ok);
}

fn host_calls(_: void, smith: *Smith) anyerror!void {
    _ = try check_calls(.{ .smith = smith });
}

/// A generated story and a sequence of host calls on it; whether it compiled.
fn check_calls(choices: fuzz_ink.Choices) !bool {
    const gpa = std.testing.allocator;
    var buffer: [fuzz_ink.source_bytes_max]u8 = undefined;
    var program = try play.compile_story(gpa, choices, &buffer) orelse return false;
    defer program.deinit(gpa);
    assert(program.check() == .ok);
    var story: play.Story = undefined;
    try play.init_story(&story, gpa, &program, .pick(choices));
    defer story.deinit(gpa);
    assert(story.core.program == &program);
    var kept: ?Value = null;
    var calls: u32 = 0;
    while (calls < calls_max and choices.more(7, 1)) : (calls += 1) {
        // An error is an answer. After one in the middle of a step the story fails closed
        // (error.StoryFailed) until reset_state or load_json, which the sequence may call.
        call(&story, choices, &kept) catch {};
        assert(story.core.state.check() == .ok);
    }
    assert(calls <= calls_max);
    return true;
}

test "fuzz: host calls in any order keep the state consistent" {
    // Seeded sessions first: most stories compile, and every call sequence checks.
    var sessions: u32 = 0;
    for (0..32) |seed| {
        var prng: std.Random.DefaultPrng = .init(seed);
        if (try check_calls(.{ .random = prng.random() })) sessions += 1;
    }
    try std.testing.expect(sessions > 16);
    try std.testing.fuzz({}, host_calls, .{ .corpus = &.{""} });
}
