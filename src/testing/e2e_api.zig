//! The e2e tests that drive the story API directly: flows, paths, tags, externals, observers,
//! variables and saves on compiled fixtures. They began as the old runtime's API tests, whose
//! `cont()` ran a whole turn; here that is `continue_maximally`.

const std = @import("std");
const assert = std.debug.assert;
const support = @import("support.zig");
const vm = @import("../runtime/api.zig");
const Program = @import("../core/program.zig").Program;
const Value = vm.Value;
const VmStory = @import("../runtime/story.zig").Story;

const fixtures = "test/fixture/original/";

/// A story on a fixture's program.
const Fixture = struct {
    program: Program,
    story: vm.Story,

    fn init(fixture: *Fixture, path: []const u8) !void {
        const gpa = std.testing.allocator;
        fixture.program = try support.compile_fixture(gpa, std.testing.io, path);
        errdefer fixture.program.deinit(gpa);
        try fixture.story.init(gpa, &fixture.program, .{});
    }

    fn deinit(fixture: *Fixture) void {
        fixture.story.deinit(std.testing.allocator);
        fixture.program.deinit(std.testing.allocator);
    }

    /// The old runtime's `cont()`: everything up to the next choice or the end.
    fn turn(fixture: *Fixture) ![]u8 {
        return fixture.story.continue_maximally_alloc(std.testing.allocator);
    }
};

fn expect_contains(text: []const u8, part: []const u8) !void {
    if (std.mem.indexOf(u8, text, part) != null) return;
    std.debug.print("expected {s} in: {s}\n", .{ part, text });
    return error.TestExpectedPart;
}

test "multiflow/multi_flow_basics.ink" {
    var fixture: Fixture = undefined;
    try fixture.init(fixtures ++ "runtime/multiflow/multi_flow_basics.ink");
    defer fixture.deinit();
    try fixture.story.switch_flow("f1");
    try fixture.story.choose_path_string("knot1", .{});
    const first = try fixture.turn();
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("knot 1 line 1\nknot 1 line 2\n", first);
    try fixture.story.switch_flow("f2");
    try fixture.story.choose_path_string("knot2", .{});
    const second = try fixture.turn();
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("knot 2 line 1\nknot 2 line 2\n", second);
}

test "multiflow/multi_flow_save_load_threads.ink" {
    var fixture: Fixture = undefined;
    try fixture.init(fixtures ++ "runtime/multiflow/multi_flow_save_load_threads.ink");
    defer fixture.deinit();
    const text = try fixture.turn();
    defer std.testing.allocator.free(text);
    try expect_contains(text, "Default line 1");
}

test "builtins/visit_counts_when_choosing.ink" {
    var fixture: Fixture = undefined;
    try fixture.init(fixtures ++ "runtime/builtins/visit_counts_when_choosing.ink");
    defer fixture.deinit();
    try fixture.story.choose_path_string("TestKnot", .{});
    const first = try fixture.turn();
    defer std.testing.allocator.free(first);
    try expect_contains(first, "this is a test");
    try fixture.story.choose_choice_index(0);
    const second = try fixture.turn();
    defer std.testing.allocator.free(second);
    try expect_contains(second, "this is the end");
}

test "choices/choice_thread_forking.ink" {
    var fixture: Fixture = undefined;
    try fixture.init(fixtures ++ "runtime/choices/choice_thread_forking.ink");
    defer fixture.deinit();
    const first = try fixture.turn();
    defer std.testing.allocator.free(first);
    try std.testing.expectEqual(@as(u32, 1), fixture.story.current_choices_count());
    try std.testing.expectEqualStrings("A choice", fixture.story.current_choice(0).get().text);
    try fixture.story.choose_choice_index(0);
    const second = try fixture.turn();
    defer std.testing.allocator.free(second);
    try expect_contains(second, "A choice");
    try expect_contains(second, "Vaue of local var is: ");
}

test "player/error_and_exceptions.ink" {
    var fixture: Fixture = undefined;
    try fixture.init(fixtures ++ "player/error_and_exceptions.ink");
    defer fixture.deinit();
    try fixture.story.choose_path_string("knot", .{});
    const text = try fixture.turn();
    defer std.testing.allocator.free(text);
    try expect_contains(text, "This is a knot");
}

const TagCounter = struct {
    count: u32 = 0,

    pub fn tag(counter: *TagCounter, _: []const u8) !void {
        counter.count += 1;
    }
};

test "player/flow.ink" {
    var fixture: Fixture = undefined;
    try fixture.init(fixtures ++ "player/flow.ink");
    defer fixture.deinit();
    var tags: TagCounter = .{};
    try fixture.story.global_tags(&tags);
    try std.testing.expect(tags.count >= 2);
    const text = try fixture.turn();
    defer std.testing.allocator.free(text);
    try expect_contains(text, "Hello");
}

/// The old tests' external functions.
const Externals = struct {
    fn count(_: ?*anyopaque, _: *VmStory, arguments: []const Value) anyerror!Value {
        if (arguments.len == 0) return .{ .integer = 3 };
        return switch (arguments[0]) {
            .integer => |value| .{ .integer = value + 3 },
            else => .{ .integer = 3 },
        };
    }

    fn nothing(_: ?*anyopaque, _: *VmStory, _: []const Value) anyerror!Value {
        return .null;
    }

    fn multiply(_: ?*anyopaque, _: *VmStory, arguments: []const Value) anyerror!Value {
        assert(arguments.len == 2);
        return .{ .float = as_float(arguments[0]) * as_float(arguments[1]) };
    }

    fn as_float(value: Value) f32 {
        return switch (value) {
            .float => |float| float,
            .integer => |integer| @floatFromInt(integer),
            else => 0,
        };
    }

    fn times(_: ?*anyopaque, _: *VmStory, _: []const Value) anyerror!Value {
        return .{ .string = "knock knock knock " };
    }

    fn increment(_: ?*anyopaque, _: *VmStory, arguments: []const Value) anyerror!Value {
        assert(arguments.len == 1);
        const value: i32 = if (arguments[0] == .integer) arguments[0].integer else 0;
        return .{ .integer = value + 1 };
    }
};

test "player/functions.ink" {
    var fixture: Fixture = undefined;
    try fixture.init(fixtures ++ "player/functions.ink");
    defer fixture.deinit();
    try fixture.story.bind_external_function("external_function", .{}, null, Externals.count);
    const text = try fixture.turn();
    defer std.testing.allocator.free(text);
    try expect_contains(text, "The count is 7");
}

test "player/variable_observation.ink" {
    var fixture: Fixture = undefined;
    try fixture.init(fixtures ++ "player/variable_observation.ink");
    defer fixture.deinit();
    try std.testing.expect(fixture.story.get_variable("aBoolean") != null);
    const number = fixture.story.get_variable("anInteger") orelse return error.TestExpectedVariable;
    try std.testing.expectEqual(Value{ .integer = 3 }, number.get());
}

test "player/variables.ink" {
    var fixture: Fixture = undefined;
    try fixture.init(fixtures ++ "player/variables.ink");
    defer fixture.deinit();
    const text = try fixture.turn();
    defer std.testing.allocator.free(text);
    try expect_contains(text, "Hello World");
    try std.testing.expect(fixture.story.current_choices_count() >= 1);
}

test "runtime/bindings/external_binding.ink" {
    var fixture: Fixture = undefined;
    try fixture.init(fixtures ++ "runtime/bindings/external_binding.ink");
    defer fixture.deinit();
    try fixture.story.bind_external_function("message", .{}, null, Externals.nothing);
    try fixture.story.bind_external_function("multiply", .{}, null, Externals.multiply);
    try fixture.story.bind_external_function("times", .{}, null, Externals.times);
    const text = try fixture.turn();
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("15\nknock knock knock\n", text);
}

test "runtime/bindings/game_ink_back_and_forth.ink" {
    var fixture: Fixture = undefined;
    try fixture.init(fixtures ++ "runtime/bindings/game_ink_back_and_forth.ink");
    defer fixture.deinit();
    try fixture.story.bind_external_function("gameInc", .{}, null, Externals.increment);
    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    const arguments = [_]Value{.{ .integer = 5 }};
    _ = try fixture.story.evaluate_function("topExternal", &arguments, &text.writer);
    try expect_contains(text.written(), "In top external");
}

test "runtime/bindings/lookup_safe_or_not.ink" {
    var fixture: Fixture = undefined;
    try fixture.init(fixtures ++ "runtime/bindings/lookup_safe_or_not.ink");
    defer fixture.deinit();
    try fixture.story.bind_external_function("myAction", .{}, null, Externals.nothing);
    const text = try fixture.turn();
    defer std.testing.allocator.free(text);
    try expect_contains(text, "One");
    try expect_contains(text, "Two");
}

test "runtime/bindings/lookup_safe_or_not_with_post_glue.ink" {
    var fixture: Fixture = undefined;
    try fixture.init(fixtures ++ "runtime/bindings/lookup_safe_or_not_with_post_glue.ink");
    defer fixture.deinit();
    try fixture.story.bind_external_function("myAction", .{}, null, Externals.nothing);
    const text = try fixture.turn();
    defer std.testing.allocator.free(text);
    try expect_contains(text, "One");
    try expect_contains(text, "Two");
}

const Observed = struct {
    count: u32 = 0,
    last: i32 = 0,

    fn observe(context: ?*anyopaque, name: []const u8, value: Value) void {
        assert(std.mem.eql(u8, name, "testVar"));
        const observed: *Observed = @ptrCast(@alignCast(context.?));
        observed.count += 1;
        if (value == .integer) observed.last = value.integer;
    }
};

test "runtime/bindings/variable_observer.ink" {
    var fixture: Fixture = undefined;
    try fixture.init(fixtures ++ "runtime/bindings/variable_observer.ink");
    defer fixture.deinit();
    var observed: Observed = .{};
    try fixture.story.observe_variable("testVar", &observed, Observed.observe);
    const first = try fixture.turn();
    defer std.testing.allocator.free(first);
    try expect_contains(first, "Hello world!");
    try std.testing.expectEqual(@as(u32, 1), observed.count);
    try std.testing.expectEqual(@as(i32, 15), observed.last);
    try fixture.story.choose_choice_index(0);
    const second = try fixture.turn();
    defer std.testing.allocator.free(second);
    try std.testing.expectEqual(@as(u32, 2), observed.count);
    try std.testing.expectEqual(@as(i32, 25), observed.last);
}

/// Plays up to `turns` turns, taking the first or the last choice.
fn play(fixture: *Fixture, turns: u32, last: bool) ![]u8 {
    const gpa = std.testing.allocator;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);
    for (0..turns) |_| {
        const story = &fixture.story;
        if (story.can_continue()) {
            const line = try story.cont_alloc(gpa);
            defer gpa.free(line);
            try output.appendSlice(gpa, line);
        } else if (story.current_choices_count() > 0) {
            const count = story.current_choices_count();
            try story.choose_choice_index(if (last) count - 1 else 0);
        } else break;
    }
    return output.toOwnedSlice(gpa);
}

test "simple_taster_tutorial.ink: always the first choice" {
    var fixture: Fixture = undefined;
    try fixture.init("test/fixture/simple_taster_tutorial.ink");
    defer fixture.deinit();
    // The old test played 20 turns of whole-turn cont(); lines are finer, so allow more.
    const text = try play(&fixture, 400, false);
    defer std.testing.allocator.free(text);
    try expect_contains(text, "we passed the day in silence");
}

test "crime_scene.ink: always the last choice" {
    var fixture: Fixture = undefined;
    try fixture.init("test/fixture/crime_scene.ink");
    defer fixture.deinit();
    const text = try play(&fixture, 1200, true);
    defer std.testing.allocator.free(text);
    try expect_contains(text, "bedroom");
}
