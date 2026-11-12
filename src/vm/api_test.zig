//! The public API test (plan P6.3): every public method of `api.Story`, every limit error,
//! two stories sharing one program, reentrancy, and ChoosePathString inside a function. The
//! stories are compiled by ink (test/fixture/api/*.ink).

const std = @import("std");
const assert = std.debug.assert;
const api = @import("api.zig");
const ink_json = @import("../core/ink_json.zig");
const Program = @import("../core/program.zig").Program;
const Story = api.Story;
const Value = api.Value;

const tour_path = "test/fixture/api/tour.ink.json";
const limits_path = "test/fixture/api/limits.ink.json";

fn read(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    assert(std.mem.endsWith(u8, path, ".json"));
    assert(path.len > 0);
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, arena, .limited(1 << 20));
}

const Recorder = struct {
    greeted: u32 = 0,
    observed: u32 = 0,
    last_score: i32 = 0,
    tags: u32 = 0,
    names: u32 = 0,
    errors: u32 = 0,
    /// Make the external call cont (reentrancy) or evaluate a function (nesting).
    mode: enum { plain, reenter, evaluate } = .plain,
    reentrant: bool = false,

    fn greet(
        context: ?*anyopaque,
        story: *@import("story.zig").Story,
        arguments: []const Value,
    ) anyerror!Value {
        assert(context != null);
        const recorder: *Recorder = @ptrCast(@alignCast(context.?));
        assert(arguments.len == 1 and arguments[0] == .string);
        recorder.greeted += 1;
        switch (recorder.mode) {
            .plain => {},
            .reenter => {
                _ = story.cont() catch |err| {
                    recorder.reentrant = err == error.Reentrant;
                };
            },
            .evaluate => {
                var discarding: std.Io.Writer.Discarding = .init(&.{});
                _ = try @import("evaluate.zig").evaluate_function(
                    story,
                    "double",
                    &.{.{ .integer = 1 }},
                    &discarding.writer,
                );
            },
        }
        return .{ .integer = 5 };
    }

    fn observe_any(context: ?*anyopaque, variable: []const u8, value: Value) void {
        assert(context != null);
        const recorder: *Recorder = @ptrCast(@alignCast(context.?));
        assert(variable.len > 0 and value != .string or value == .string);
        recorder.observed += 1;
    }

    fn observe(context: ?*anyopaque, variable: []const u8, value: Value) void {
        assert(context != null);
        const recorder: *Recorder = @ptrCast(@alignCast(context.?));
        assert(std.mem.eql(u8, variable, "score"));
        recorder.observed += 1;
        recorder.last_score = value.integer;
    }

    pub fn tag(recorder: *Recorder, text: []const u8) !void {
        assert(recorder.greeted < 1 << 20);
        assert(text.len > 0);
        recorder.tags += 1;
    }

    pub fn name(recorder: *Recorder, text: []const u8) !void {
        assert(recorder.greeted < 1 << 20);
        assert(text.len > 0);
        recorder.names += 1;
    }

    fn on_error(context: ?*anyopaque, message: []const u8, severity: api.Severity) void {
        assert(context != null);
        const recorder: *Recorder = @ptrCast(@alignCast(context.?));
        assert(message.len > 0 and severity == .@"error");
        recorder.errors += 1;
    }
};

test "the public API, method by method" {
    // Goal: P6.3; every public method of api.Story on one story. Method: play the tour.
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var story: Story = undefined;
    try story.init_from_json(gpa, try read(arena, tour_path), .{ .random_seed = 3 });
    defer story.deinit(gpa);
    var recorder: Recorder = .{};
    try story.bind_external_function("greet", .{}, &recorder, Recorder.greet);
    try std.testing.expectError(
        error.AlreadyBound,
        story.bind_external_function("greet", .{}, &recorder, Recorder.greet),
    );
    try story.observe_variable("score", &recorder, Recorder.observe);
    try std.testing.expectError(
        error.VariableNotDeclared,
        story.observe_variable("nope", &recorder, Recorder.observe),
    );
    try story.global_tags(&recorder);
    try std.testing.expectEqual(@as(u32, 1), recorder.tags);
    try std.testing.expect(story.can_continue());
    try std.testing.expectEqualStrings("Hello\n", (try story.cont()).get());
    // The first line carries the global tags too, as in ink.
    try story.current_tags(&recorder);
    try std.testing.expectEqual(@as(u32, 3), recorder.tags);
    try std.testing.expectEqualStrings("Hello\n", (try story.current_text()).get());
    try std.testing.expect(!story.can_continue());
    try std.testing.expectEqual(@as(u32, 1), recorder.greeted);
    try std.testing.expectEqual(@as(i32, 5), recorder.last_score);
    try std.testing.expectEqual(@as(u32, 2), story.current_choices_count());
    const left = story.current_choice(0).get();
    try std.testing.expectEqualStrings("Left", left.text);
    try std.testing.expectEqual(@as(u32, 1), left.tags_count);
    try std.testing.expectEqualStrings("choice tag", story.current_choice_tag(0, 0).get());
    try std.testing.expectError(error.ChoiceLimit, story.choose_choice_index(2));
    try story.choose_choice_index(0);
    const rest = try story.continue_maximally_alloc(gpa);
    defer gpa.free(rest);
    try std.testing.expectEqualStrings("Went left\nDone 5\n", rest);
    try std.testing.expectEqual(@as(i32, 5), story.get_variable("score").?.get().integer);
    try std.testing.expect(story.get_variable("missing") == null);
    try story.set_variable("score", .{ .integer = 9 });
    try story.set_variable("name", .{ .string = "set by the host" });
    try std.testing.expectError(error.VariableNotDeclared, story.set_variable("missing", .{
        .integer = 1,
    }));
    try std.testing.expectEqualStrings(
        "set by the host",
        story.get_variable("name").?.get().string,
    );
    try std.testing.expectEqual(@as(u32, 3), story.global_variable_count());
    try std.testing.expectEqualStrings("score", story.global_variable_name(0));
    // Choice targets count visits (for once-only choices); the label isn't counted.
    try std.testing.expectEqual(@as(u32, 1), story.visit_count_at_path_string("0.c-0"));
    try std.testing.expectEqual(@as(u32, 0), story.visit_count_at_path_string("0.end"));
    try story.tags_for_content_at_path("knot", &recorder);
    try std.testing.expectEqual(@as(u32, 4), recorder.tags);
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    const doubled = try story.evaluate_function("double", &.{.{ .integer = 21 }}, &text.writer);
    try std.testing.expectEqual(@as(i32, 42), doubled.get().integer);
    try std.testing.expectError(
        error.FunctionNotFound,
        story.evaluate_function("missing", &.{}, &text.writer),
    );
    try story.choose_path_string("with_parameter", .{ .arguments = &.{.{ .string = "hi" }} });
    const said = try story.cont_alloc(gpa);
    defer gpa.free(said);
    try std.testing.expectEqualStrings("Said hi\n", said);
    try std.testing.expectError(error.PathNotFound, story.choose_path_string("nowhere", .{}));
    try exercise_flows_and_saves(&story, &recorder, gpa);
    try story.unbind_external_function("greet");
    try std.testing.expectError(error.NotBound, story.unbind_external_function("greet"));
}

fn exercise_flows_and_saves(story: *Story, recorder: *Recorder, gpa: std.mem.Allocator) !void {
    assert(story.core.state.memory.len > 0);
    assert(story.can_continue() == false);
    try story.switch_flow("side");
    try std.testing.expectEqualStrings("side", story.current_flow_name().get());
    try story.alive_flow_names(recorder);
    try std.testing.expectEqual(@as(u32, 1), recorder.names);
    try story.switch_to_default_flow();
    try story.remove_flow("side");
    var saved: std.Io.Writer.Allocating = .init(gpa);
    defer saved.deinit();
    try story.to_json(&saved.writer);
    try story.reset_state();
    try std.testing.expectEqual(@as(i32, 0), story.get_variable("score").?.get().integer);
    try story.load_json(saved.written());
    try std.testing.expectEqual(@as(i32, 9), story.get_variable("score").?.get().integer);
    try std.testing.expectError(error.InvalidSave, story.load_json("{}"));
    // Without an error handler, errors are kept for the host.
    try story.choose_path_string("in_function", .{});
    try std.testing.expectEqualStrings("First\n", (try story.cont()).get());
    try std.testing.expectError(error.ChoosePathInFunction, story.choose_path_string("knot", .{
        .reset_callstack = false,
    }));
    try std.testing.expect(!story.has_error() and !story.has_warning());
    try std.testing.expectEqual(@as(u32, 0), story.error_count() + story.warning_count());
    story.reset_errors();
}

test "errors without a handler are kept for the host" {
    // Goal: P6.3 has_error, error_count, write_error and reset_errors. Method: a knot that
    // runs out of content, played without a handler, then with one.
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const json = try read(arena, cases_ink_json("audit/errors_end_of_content"));
    var story: Story = undefined;
    try story.init_from_json(gpa, json, .{});
    defer story.deinit(gpa);
    _ = try story.cont();
    try std.testing.expectError(error.StoryError, story.cont());
    try std.testing.expect(story.has_error());
    try std.testing.expectEqual(@as(u32, 1), story.error_count());
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try story.write_error(0, &writer);
    const message = writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, message, "RUNTIME ERROR: ran out of content"));
    story.reset_errors();
    try std.testing.expect(!story.has_error());
    var recorder: Recorder = .{};
    var handled: Story = undefined;
    try handled.init_from_json(gpa, json, .{
        .error_context = &recorder,
        .on_error = Recorder.on_error,
    });
    defer handled.deinit(gpa);
    _ = try handled.cont();
    _ = try handled.cont();
    try std.testing.expectEqual(@as(u32, 1), recorder.errors);
}

fn cases_ink_json(comptime id: []const u8) []const u8 {
    comptime assert(id.len > 0);
    comptime assert(id[0] != '/');
    return "test/ground_truth/" ++ id ++ ".ink.json";
}

test "two stories share one program and run independently" {
    // Goal: P6.3; a Program is immutable and shareable. Method: two stories on one program
    // take different choices.
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var program = try ink_json.load(gpa, try read(arena_state.allocator(), tour_path));
    defer program.deinit(gpa);
    var stories: [2]Story = undefined;
    var recorders: [2]Recorder = .{ .{}, .{} };
    for (&stories, &recorders, 0..) |*story, *recorder, position| {
        try story.init(gpa, &program, .{});
        try story.bind_external_function("greet", .{}, recorder, Recorder.greet);
        _ = try story.cont();
        try story.choose_choice_index(@intCast(position));
    }
    defer for (&stories) |*story| story.deinit(gpa);
    try std.testing.expectEqualStrings("Went left\n", (try stories[0].cont()).get());
    try std.testing.expectEqualStrings("Right\n", (try stories[1].cont()).get());
    try std.testing.expect(stories[0].get_program() == stories[1].get_program());
}

test "a mutating call from a callback is reentrant, and evaluate may nest" {
    // Goal: P6.3 reentrancy. Method: an external that calls cont, then one that evaluates a
    // function, with evaluate_depth_max 1 so the nested evaluation is refused.
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const json = try read(arena_state.allocator(), tour_path);
    var recorder: Recorder = .{ .mode = .reenter };
    var story: Story = undefined;
    try story.init_from_json(gpa, json, .{});
    defer story.deinit(gpa);
    try story.bind_external_function("greet", .{}, &recorder, Recorder.greet);
    _ = try story.cont();
    try std.testing.expect(recorder.reentrant);
    var shallow: Story = undefined;
    try shallow.init_from_json(gpa, json, .{ .limits = .{ .evaluate_depth_max = 1 } });
    defer shallow.deinit(gpa);
    var nesting: Recorder = .{ .mode = .evaluate };
    try shallow.bind_external_function("greet", .{}, &nesting, Recorder.greet);
    var discarding: std.Io.Writer.Discarding = .init(&.{});
    try std.testing.expectError(
        error.ExternalFunctionFailed,
        shallow.evaluate_function("shout", &.{}, &discarding.writer),
    );
}

/// A limits story positioned at `knot`.
fn limited(gpa: std.mem.Allocator, json: []const u8, limits: api.Limits, knot: []const u8) !*Story {
    assert(@sizeOf(std.mem.Allocator) > 0);
    assert(@sizeOf(Story) > 0);
    const story = try gpa.create(Story);
    errdefer gpa.destroy(story);
    try story.init_from_json(gpa, json, .{ .limits = limits });
    try story.choose_path_string(knot, .{});
    return story;
}

fn drop(gpa: std.mem.Allocator, story: *Story) void {
    assert(@sizeOf(std.mem.Allocator) > 0);
    assert(@sizeOf(Story) > 0);
    story.deinit(gpa);
    gpa.destroy(story);
}

fn play_until_error(story: *Story) !void {
    assert(story.core.state.memory.len > 0);
    assert(story.core.program.containers.len > 0);
    var lines: u32 = 0;
    while (story.can_continue()) : (lines += 1) {
        if (lines == 1000) return error.NoLimitHit;
        _ = try story.cont();
        if (story.current_choices_count() > 0) try story.choose_choice_index(0);
    }
    return error.NoLimitHit;
}

test "every limit error of cont" {
    // Goal: P6.3; each buffer limit returns its own error. Method: one knot per limit, with
    // that limit made small.
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const json = try read(arena_state.allocator(), limits_path);
    const Case = struct { knot: []const u8, limits: api.Limits, expected: anyerror };
    const limit_cases = [_]Case{
        .{
            .knot = "deep_expression",
            .limits = .{ .evaluation_values_max = 3 },
            .expected = error.EvaluationLimit,
        },
        .{
            .knot = "recursion",
            .limits = .{ .frames_max = 8, .threads_max = 4 },
            .expected = error.FrameLimit,
        },
        .{
            .knot = "threads",
            .limits = .{ .threads_max = 1 },
            .expected = error.ThreadLimit,
        },
        .{
            .knot = "many_temps",
            .limits = .{ .temps_max = 4, .temps_per_frame_max = 4 },
            .expected = error.TempLimit,
        },
        .{
            .knot = "long_line",
            .limits = .{ .output_items_max = 8 },
            .expected = error.OutputLimit,
        },
        .{
            .knot = "many_choices",
            .limits = .{ .choices_max = 2 },
            .expected = error.ChoiceLimit,
        },
        .{
            .knot = "tagged_choices",
            .limits = .{ .tags_max = 4 },
            .expected = error.TagLimit,
        },
        .{
            .knot = "tunnel_choice",
            .limits = .{ .choice_snapshot_frames_max = 1 },
            .expected = error.SnapshotLimit,
        },
        .{
            .knot = "concatenation",
            .limits = .{ .heap_bytes_max = 64 },
            .expected = error.HeapLimit,
        },
        .{
            .knot = "lists",
            .limits = .{ .list_words_max = 4 },
            .expected = error.ListLimit,
        },
        .{
            .knot = "globals_after_newline",
            .limits = .{ .patch_entries_max = 1 },
            .expected = error.LookaheadLogLimit,
        },
        .{
            .knot = "two_globals",
            .limits = .{ .observer_events_max = 1 },
            .expected = error.ObserverQueueLimit,
        },
        .{
            .knot = "loop",
            .limits = .{ .steps_per_continue_max = 100 },
            .expected = error.StepLimit,
        },
    };
    for (limit_cases) |case| {
        const story = try limited(gpa, json, case.limits, case.knot);
        defer drop(gpa, story);
        if (case.expected == error.ObserverQueueLimit) {
            var recorder: Recorder = .{};
            try story.observe_variable("x", &recorder, Recorder.observe_any);
            try story.observe_variable("y", &recorder, Recorder.observe_any);
        }
        play_until_error(story) catch |err| {
            std.testing.expectEqual(case.expected, err) catch |mismatch| {
                std.debug.print("knot {s}: {t}\n", .{ case.knot, err });
                return mismatch;
            };
            continue;
        };
    }
}

test "the other limit errors" {
    // Goal: P6.3; observers, flows, text length, evaluate depth and save size. Method: the
    // call that runs into each.
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const json = try read(arena, tour_path);
    var recorder: Recorder = .{};
    var story: Story = undefined;
    try story.init_from_json(
        gpa,
        json,
        .{ .limits = .{ .observers_max = 1, .flows_max = 2, .load_nodes_max = 16 } },
    );
    defer story.deinit(gpa);
    try story.observe_variable("score", &recorder, Recorder.observe);
    try std.testing.expectError(
        error.ObserverLimit,
        story.observe_variable("score", &recorder, Recorder.observe),
    );
    try story.switch_flow("one");
    try std.testing.expectError(error.FlowLimit, story.switch_flow("two"));
    const too_long = "123456789012345678901234567890123456789012345678901";
    try std.testing.expectError(error.FlowNameTooLong, story.switch_flow(too_long));
    try story.switch_to_default_flow();
    var saved: std.Io.Writer.Allocating = .init(gpa);
    defer saved.deinit();
    try story.to_json(&saved.writer);
    try std.testing.expectError(error.SaveTooLarge, story.load_json(saved.written()));
    var tight: Story = undefined;
    try tight.init_from_json(gpa, json, .{ .limits = .{ .flow_parking_bytes_max = 32 } });
    defer tight.deinit(gpa);
    try std.testing.expectError(error.FlowParkingLimit, tight.switch_flow("parked"));
    try tight.bind_external_function("greet", .{}, &recorder, Recorder.greet);
    const long_name = try arena.alloc(u8, 70_000);
    @memset(long_name, 'n');
    try tight.set_variable("name", .{ .string = long_name });
    try tight.choose_path_string("print_name", .{});
    try std.testing.expectError(error.TextTooLong, tight.cont());
}
