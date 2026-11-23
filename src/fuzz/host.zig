//! Fuzz target for the host API: on a generated story, a fuzzer-chosen sequence
//! of the calls a host makes, with names and values from the story's pool and outside it.
//! Every call returns a result or an error, and the state checks after each one.

const std = @import("std");
const assert = std.debug.assert;
const fuzz_ink = @import("../testing/fuzz_ink.zig");
const play = @import("play.zig");
const Program = @import("../core/program.zig").Program;

const Value = play.Value;
/// The calls a session makes at most.
pub const calls_max = 48;

pub const Call = enum {
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
    /// P19.8: `cont_alloc`; `continue_maximally` into a writer of 256 bytes, which a story
    /// that runs on fills (`error.WriteFailed`); the kept errors and warnings, each written
    /// out, then (half the time) `reset_errors`; `unbind_external_function`, then (half the
    /// time) `e0` bound again, lookahead-safe or not.
    cont_alloc,
    continue_maximally,
    errors,
    unbind,
};

/// The calls a session may make (a swarm over calls, plan §3.5). `cont` is always in it, so
/// stories advance; leaving out `reset` and `save_and_load`, which wipe or rebuild the
/// state, gives long sessions their depth.
pub const CallSet = std.EnumSet(Call);

/// Every call with weight 1/8, else each one with probability ½, and `cont`.
pub fn draw_calls(choices: fuzz_ink.Choices) CallSet {
    var calls = fuzz_ink.draw_subset(choices, Call);
    calls.insert(.cont);
    assert(calls.contains(.cont));
    return calls;
}

const paths = [_][]const u8{ "k0", "k1", "k2", "k0.s0", "f0", "e0", "k0.s1", "missing", "0" };
const variables = [_][]const u8{ "v0", "v1", "v2", "c0", "l0", "missing" };
const functions = [_][]const u8{ "f0", "f1", "e0", "k0", "missing" };
const flows = [_][]const u8{ "DEFAULT_FLOW", "one", "two" };
const externals = [_][]const u8{ "e0", "missing" };

const Sink = struct {
    count: u32 = 0,

    pub fn tag(sink: *Sink, text: []const u8) !void {
        assert(text.len < 1 << 20);
        sink.count += 1;
    }

    pub fn name(sink: *Sink, _: []const u8) !void {
        sink.count += 1;
    }
};

fn pick(choices: fuzz_ink.Choices, comptime list: []const []const u8) []const u8 {
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

/// One host call from `calls`; returns which. `kept` is the last divert target read, so one
/// goes back in (strings and lists are views, valid only until the next mutating call).
/// `gpa` holds a save for `save_and_load`. The caller checks the state after the call (the
/// swarm's host target reports a failed check instead of stopping at an assertion).
pub fn call(
    gpa: std.mem.Allocator,
    story: *play.Story,
    choices: fuzz_ink.Choices,
    kept: *?Value,
    calls: CallSet,
) !Call {
    assert(story.state.check() == .ok);
    assert(calls.contains(.cont));
    const kind = pick_call(choices, calls);
    try make_call(gpa, story, choices, kept, kind);
    return kind;
}

/// The next call of a session, from `calls`.
pub fn pick_call(choices: fuzz_ink.Choices, calls: CallSet) Call {
    assert(calls.contains(.cont));
    // The full set takes the choice the target took before swarms.
    if (calls.eql(.full)) return choices.choose(Call);
    return fuzz_ink.pick_from(choices, Call, calls);
}

/// Call `kind`, as `call` does.
pub fn make_call(
    gpa: std.mem.Allocator,
    story: *play.Story,
    choices: fuzz_ink.Choices,
    kept: *?Value,
    kind: Call,
) !void {
    var sink: Sink = .{};
    var text: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&text);
    try call_kind(gpa, story, choices, kept, kind, &sink, &writer);
    assert(writer.end <= text.len);
}

fn call_kind(
    gpa: std.mem.Allocator,
    story: *play.Story,
    choices: fuzz_ink.Choices,
    kept: *?Value,
    kind: Call,
    sink: *Sink,
    writer: *std.Io.Writer,
) !void {
    switch (kind) {
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
            const result = try story.evaluate_function(name, arguments[0..count], writer);
            if (result.get() == .divert_target) kept.* = result.get();
        },
        .switch_flow => try story.switch_flow(pick(choices, &flows)),
        .default_flow => try story.switch_to_default_flow(),
        .remove_flow => try story.remove_flow(pick(choices, &flows)),
        .reset => try story.reset_state(),
        .visit_count => _ = story.visit_count_at_path_string(pick(choices, &paths)),
        .current_tags => try story.current_tags(sink),
        .global_tags => try story.global_tags(sink),
        .path_tags => try story.tags_for_content_at_path(pick(choices, &paths), sink),
        .current_text => _ = try story.current_text(),
        .flow_names => try story.alive_flow_names(sink),
        .save_and_load => try save_and_load(gpa, story),
        .cont_alloc => if (story.can_continue()) gpa.free(try story.cont_alloc(gpa)),
        .continue_maximally => try story.continue_maximally(writer),
        .errors => try read_errors(story, choices.choose(bool)),
        .unbind => {
            const name = pick(choices, &externals);
            try story.unbind_external_function(name);
            if (choices.choose(bool)) {
                const options: play.BindOptions = .{ .lookahead_safe = choices.choose(bool) };
                try story.bind_external_function(name, options, null, play.echo);
            }
        },
    }
}

/// Writes out every kept error and warning (and asks for one past each), then resets them
/// when `reset`.
fn read_errors(story: *play.Story, reset: bool) !void {
    var buffer: [64]u8 = undefined;
    var discarding: std.Io.Writer.Discarding = .init(&buffer);
    const writer = &discarding.writer;
    assert(story.has_error() == (story.error_count() > 0));
    assert(story.has_warning() == (story.warning_count() > 0));
    for (0..story.error_count()) |position| try story.write_error(@intCast(position), writer);
    for (0..story.warning_count()) |position| try story.write_warning(@intCast(position), writer);
    if (story.write_error(story.error_count(), writer)) |_| unreachable else |_| {}
    if (story.write_warning(story.warning_count(), writer)) |_| unreachable else |_| {}
    if (reset) try story.reset_errors();
}

/// A save loaded back into the story it came from.
fn save_and_load(gpa: std.mem.Allocator, story: *play.Story) !void {
    assert(story.state.check() == .ok);
    var save: std.Io.Writer.Allocating = .init(gpa);
    defer save.deinit();
    try story.to_json(&save.writer);
    try story.load_json(save.written());
    assert(story.state.check() == .ok);
}

/// Whether a story compiled and its session ran.
fn host_calls(choices: fuzz_ink.Choices) !bool {
    return try check_calls(choices) != null;
}

/// What a session drew and made.
const Session = struct { calls: CallSet, made: CallSet };

/// A generated story and a sequence of host calls on it; null when it didn't compile.
fn check_calls(choices: fuzz_ink.Choices) !?Session {
    const gpa = std.testing.allocator;
    var buffer: [fuzz_ink.source_bytes_max]u8 = undefined;
    var program = try play.compile_story(gpa, choices, &buffer) orelse return null;
    defer program.deinit(gpa);
    return try session_on(&program, choices);
}

/// A session of host calls on a story of `program`.
fn session_on(program: *const Program, choices: fuzz_ink.Choices) !Session {
    const gpa = std.testing.allocator;
    assert(program.check() == .ok);
    var story: play.Story = undefined;
    var setup: play.Setup = .pick(choices);
    setup.evaluate_in_external = choices.choose(bool);
    try play.init_story(&story, gpa, program, setup);
    defer story.deinit(gpa);
    assert(story.program == program);
    const calls = draw_calls(choices);
    var session: Session = .{ .calls = calls, .made = .empty };
    var kept: ?Value = null;
    var count: u32 = 0;
    while (count < calls_max and choices.more(7, 1)) : (count += 1) {
        // An error is an answer. After one in the middle of a step the story fails closed
        // (error.StoryFailed) until reset_state or load_json, which the sequence may call.
        const made = call(gpa, &story, choices, &kept, calls) catch continue;
        session.made.insert(made);
        assert(story.state.check() == .ok);
    }
    assert(count <= calls_max);
    return session;
}

test "fuzz: host calls in any order keep the state consistent" {
    // Seeded sessions first: most stories compile, and every call sequence checks.
    try fuzz_ink.run_target(host_calls, 16);
}

test "fuzz: a session makes only the calls it drew" {
    // 1,000 seeded sessions on 8 seeded stories: every call made is in the session's set,
    // `cont` is in every set, and some sessions leave out both suppressors (reset and
    // save_and_load).
    const gpa = std.testing.allocator;
    var programs: [8]Program = undefined;
    var compiled: u32 = 0;
    defer for (programs[0..compiled]) |*program| program.deinit(gpa);
    var seed: u64 = 0;
    while (compiled < programs.len) : (seed += 1) {
        try std.testing.expect(seed < 256);
        var prng: std.Random.DefaultPrng = .init(seed);
        var buffer: [fuzz_ink.source_bytes_max]u8 = undefined;
        const choices: fuzz_ink.Choices = .{ .random = prng.random() };
        programs[compiled] = try play.compile_story(gpa, choices, &buffer) orelse continue;
        compiled += 1;
    }
    var without_suppressors: u32 = 0;
    var subsets: u32 = 0;
    for (0..1000) |session_seed| {
        var prng: std.Random.DefaultPrng = .init(session_seed);
        const program = &programs[session_seed % programs.len];
        const session = try session_on(program, .{ .random = prng.random() });
        try std.testing.expect(session.calls.contains(.cont));
        try std.testing.expect(session.made.subsetOf(session.calls));
        if (!session.calls.eql(.full)) subsets += 1;
        if (!session.calls.contains(.reset) and !session.calls.contains(.save_and_load)) {
            without_suppressors += 1;
        }
    }
    try std.testing.expect(subsets > 800);
    try std.testing.expect(without_suppressors > 150);
}
