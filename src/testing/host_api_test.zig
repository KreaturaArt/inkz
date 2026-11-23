//! The host API at its edges (P14.4): strings the host got from the story passed back while
//! the heap compacts, evaluate_function and choose_path_string failing closed, a function
//! evaluated from an external during the newline lookahead, and calls from callbacks or
//! out of range that return errors instead of asserting. The stories are compiled from
//! the ink below.

const std = @import("std");
const assert = std.debug.assert;
const compile = @import("../compiler/compile.zig");
const api = @import("../runtime/story.zig");
const evaluate = @import("../runtime/evaluate.zig");

const Value = api.Value;
const support = @import("support.zig");

const strings_source =
    \\VAR a = "x"
    \\VAR b = "x"
    \\Hello
    \\Second
    \\-> DONE
    \\== knot(x, y) ==
    \\{x} {y}
    \\-> DONE
    \\== function second(x, y) ==
    \\~ return y
    \\== function divide(n) ==
    \\~ return n / 0
    \\== function double(n) ==
    \\~ return n * 2
    \\== function shout ==
    \\Loud
    \\~ return 1
    \\== function rename(x, y) ==
    \\~ a = "renamed"
    \\~ return y + "!"
    \\
;

/// A string argument longer than the 256-byte heaps below.
const long_text: [256]u8 = @splat('l');

const start = support.start;
const stop = support.stop;

fn heap_offset(story: *api.Story, name: []const u8) u32 {
    const value = story.state.globals[story.program.global_by_name(name).?.to_int()];
    assert(value == .string);
    return value.string.heap_offset();
}

test "set_variable copies a string from get_variable across a compaction" {
    // Finding 1: the text the host passes may be the heap string get_variable returned,
    // and the allocation compacts. An 80-byte heap holding the two defaults (12 bytes
    // each), a garbage string and `a` (20 bytes each): storing `b` compacts and moves `a`.
    const gpa = std.testing.allocator;
    var program = try compile.compile_source(gpa, strings_source);
    defer program.deinit(gpa);
    const story = try start(gpa, &program, .{ .heap_bytes_max = 80 });
    defer stop(gpa, story);
    try story.set_variable("a", .{ .string = "garbage text" });
    try story.set_variable("a", .{ .string = "hello world!" });
    const moved_from = heap_offset(story, "a");
    const text = story.get_variable("a").?.get().string;
    try story.set_variable("b", .{ .string = text });
    try std.testing.expect(heap_offset(story, "a") < moved_from);
    try std.testing.expectEqualStrings("hello world!", story.get_variable("a").?.get().string);
    try std.testing.expectEqualStrings("hello world!", story.get_variable("b").?.get().string);
}

test "evaluate_function and choose_path_string keep every heap string argument" {
    // Finding 2: storing the first argument compacts the heap and moved the
    // second argument's text, which also came from get_variable. Compacting on every
    // allocation, with a garbage string (`b`'s old value) below `a` and `b`.
    const gpa = std.testing.allocator;
    var program = try compile.compile_source(gpa, strings_source);
    defer program.deinit(gpa);
    const story = try start(gpa, &program, .{ .heap_bytes_max = 256 });
    defer stop(gpa, story);
    story.state.compact_always = true;
    try story.set_variable("b", .{ .string = "garbage text" });
    try story.set_variable("a", .{ .string = "first string" });
    try story.set_variable("b", .{ .string = "other string" });
    const arguments = [_]Value{
        story.get_variable("a").?.get(),
        story.get_variable("b").?.get(),
    };
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    const result = try story.evaluate_function("second", &arguments, &text.writer);
    try std.testing.expectEqualStrings("other string", result.get().string);
    const again = [_]Value{
        story.get_variable("a").?.get(),
        story.get_variable("b").?.get(),
    };
    try story.choose_path_string("knot", .{ .arguments = &again });
    try std.testing.expectEqualStrings("first string other string\n", (try story.cont()).get());
}

const lists_source =
    \\LIST l = a, b, c
    \\VAR x = (a)
    \\VAR y = (c)
    \\~ x = (b)
    \\~ y = (b, c)
    \\~ y = (a, c)
    \\Hello
    \\-> DONE
    \\== function second(s, v) ==
    \\~ return v
    \\
;

test "a list argument after a string argument survives the string's compaction" {
    // Compaction slides lists too, and only the arguments before a string were
    // kept while it was stored. `y`'s earlier values are garbage below it; storing the
    // string first compacts and moves `y`'s list, which the function must still see.
    const gpa = std.testing.allocator;
    var program = try compile.compile_source(gpa, lists_source);
    defer program.deinit(gpa);
    var story: api.Story = undefined;
    try story.init(gpa, &program, .{});
    defer story.deinit(gpa);
    _ = try story.cont();
    story.state.compact_always = true;
    const arguments = [_]Value{
        .{ .string = "a fairly long string argument" },
        story.get_variable("y").?.get(),
    };
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    const result = (try story.evaluate_function("second", &arguments, &text.writer)).get();
    try std.testing.expectEqual(story.get_variable("y").?.get().list, result.list);
    try story.set_variable("x", result);
    var written: std.Io.Writer.Allocating = .init(gpa);
    defer written.deinit();
    try api.write_list(&story, story.get_variable("x").?.get().list, &written.writer);
    try std.testing.expectEqualStrings("a, c", written.written());
}

/// Copies the arguments on_complete_evaluate_function gets.
const Completion = struct {
    texts: [2][32]u8 = undefined,
    lengths: [2]u32 = .{ 0, 0 },
    calls: u32 = 0,

    fn on_complete(
        context: ?*anyopaque,
        name: []const u8,
        arguments: []const Value,
        text: []const u8,
        result: Value,
    ) void {
        assert(name.len > 0 and text.len == 0 and result == .string);
        const completion: *Completion = @ptrCast(@alignCast(context.?));
        assert(arguments.len == 2);
        completion.calls += 1;
        for (arguments, 0..) |argument, position| {
            const length = @min(argument.string.len, 32);
            @memcpy(completion.texts[position][0..length], argument.string[0..length]);
            completion.lengths[position] = @intCast(length);
        }
    }
};

test "on_complete_evaluate_function gets its arguments after the run compacts the heap" {
    // The event got the host's own slices, which may be heap strings from
    // get_variable that the run moved. The function makes `a` garbage below `b`, then
    // concatenates, compacting on every allocation in a small heap.
    const gpa = std.testing.allocator;
    var program = try compile.compile_source(gpa, strings_source);
    defer program.deinit(gpa);
    var completion: Completion = .{};
    var story: api.Story = undefined;
    try story.init(gpa, &program, .{
        .limits = .{ .heap_bytes_max = 256 },
        .events = .{
            .context = &completion,
            .on_complete_evaluate_function = Completion.on_complete,
        },
    });
    defer story.deinit(gpa);
    story.state.compact_always = true;
    try story.set_variable("a", .{ .string = "first string" });
    try story.set_variable("b", .{ .string = "other string" });
    const arguments = [_]Value{
        story.get_variable("a").?.get(),
        story.get_variable("b").?.get(),
    };
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    const result = try story.evaluate_function("rename", &arguments, &text.writer);
    try std.testing.expectEqualStrings("other string!", result.get().string);
    try std.testing.expectEqual(@as(u32, 1), completion.calls);
    const lengths = completion.lengths;
    try std.testing.expectEqualStrings("first string", completion.texts[0][0..lengths[0]]);
    try std.testing.expectEqualStrings("other string", completion.texts[1][0..lengths[1]]);
    try std.testing.expectEqual(@as(u32, 1), story.state.call_stack.depth());
    try std.testing.expectEqual(@as(u32, 0), story.state.evaluation.count);
}

test "evaluate_function fails closed and refuses to run while errors are kept" {
    // Findings 3 and 8: before, the function's frame stayed pushed after a
    // failed setup or a full writer, and the next cont ran the function's body. Each
    // failure, then the story's own line; then a story error, which ends the flow.
    const gpa = std.testing.allocator;
    var program = try compile.compile_source(gpa, strings_source);
    defer program.deinit(gpa);
    const story = try start(gpa, &program, .{
        .heap_bytes_max = 256,
        .evaluation_values_max = 4,
    });
    defer stop(gpa, story);
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    const long: Value = .{ .string = &long_text };
    try std.testing.expectError(
        error.HeapLimit,
        story.evaluate_function("double", &.{long}, &text.writer),
    );
    const five: [5]Value = @splat(.{ .integer = 1 });
    try std.testing.expectError(
        error.EvaluationLimit,
        story.evaluate_function("double", &five, &text.writer),
    );
    var full: std.Io.Writer = .fixed(&.{});
    try std.testing.expectError(error.OutputLimit, story.evaluate_function("shout", &.{}, &full));
    try std.testing.expectEqual(@as(u32, 1), story.state.call_stack.depth());
    try std.testing.expectEqualStrings("Hello\n", (try story.cont()).get());
    // A story error ends the flow, as in cont (ink's ForceEnd): nothing of the function
    // runs later.
    try std.testing.expectError(
        error.StoryError,
        story.evaluate_function("divide", &.{.{ .integer = 1 }}, &text.writer),
    );
    // While the error is kept the function can't run: an error, not a silent null.
    try std.testing.expectError(
        error.StoryError,
        story.evaluate_function("double", &.{.{ .integer = 2 }}, &text.writer),
    );
    try story.reset_errors();
    try std.testing.expect(!story.can_continue());
    const doubled = try story.evaluate_function("double", &.{.{ .integer = 2 }}, &text.writer);
    try std.testing.expectEqual(@as(i32, 4), doubled.get().integer);
    try std.testing.expectEqual(@as(u32, 1), story.state.call_stack.depth());
    try std.testing.expect(!story.can_continue());
    try std.testing.expectEqual(@as(usize, 0), text.written().len);
}

test "choose_path_string fails closed: a failed argument leaves the flow where it was" {
    // Finding 3: before, the call stack was ended before the argument
    // failed to store. A string argument too long for the heap, mid-story.
    const gpa = std.testing.allocator;
    var program = try compile.compile_source(gpa, strings_source);
    defer program.deinit(gpa);
    const story = try start(gpa, &program, .{ .heap_bytes_max = 256 });
    defer stop(gpa, story);
    try std.testing.expectEqualStrings("Hello\n", (try story.cont()).get());
    const arguments = [_]Value{
        .{ .integer = 1 },
        .{ .string = &long_text },
    };
    try std.testing.expectError(
        error.HeapLimit,
        story.choose_path_string("knot", .{ .arguments = &arguments }),
    );
    try std.testing.expect(story.can_continue());
    try std.testing.expectEqualStrings("Second\n", (try story.cont()).get());
}

const lookahead_source =
    \\EXTERNAL ext()
    \\A line
    \\~ ext()
    \\Next
    \\-> DONE
    \\== function inner ==
    \\x
    \\<> y
    \\~ return 1
    \\
;

const Nester = struct {
    calls: u32 = 0,
    text: [64]u8 = undefined,
    length: u32 = 0,

    fn call(context: ?*anyopaque, story: *api.Story, arguments: []const Value) anyerror!Value {
        assert(arguments.len == 0);
        const nester: *Nester = @ptrCast(@alignCast(context.?));
        nester.calls += 1;
        var writer: std.Io.Writer = .fixed(&nester.text);
        const result = try evaluate.evaluate_function(story, "inner", &.{}, &writer);
        nester.length = @intCast(writer.end);
        return result;
    }
};

test "a function evaluated from an external in the lookahead leaves the outer snapshot alone" {
    // Finding 4: the nested Continue compared its text with, and restored, the
    // outer cont's newline snapshot. A lookahead-safe external called after a newline that
    // evaluates a two-line function; the lookahead runs it, then again on the next line.
    const gpa = std.testing.allocator;
    var program = try compile.compile_source(gpa, lookahead_source);
    defer program.deinit(gpa);
    const story = try start(gpa, &program, .{});
    defer stop(gpa, story);
    var nester: Nester = .{};
    try story.bind_external_function("ext", .{}, &nester, Nester.call);
    var direct: std.Io.Writer.Allocating = .init(gpa);
    defer direct.deinit();
    _ = try story.evaluate_function("inner", &.{}, &direct.writer);
    try std.testing.expectEqualStrings("A line\n", (try story.cont()).get());
    try std.testing.expectEqualStrings("Next\n", (try story.cont()).get());
    try std.testing.expectEqual(@as(u32, 2), nester.calls);
    try std.testing.expectEqualStrings(direct.written(), nester.text[0..nester.length]);
    try std.testing.expect(!story.can_continue());
}

const callbacks_source =
    \\VAR score = 0
    \\~ score = 1
    \\Line one {1 / 0}
    \\== function double(n) ==
    \\~ return n * 2
    \\
;

const choices_source =
    \\VAR score = 0
    \\Line one
    \\* [Pick # t1] Picked
    \\- -> DONE
    \\
;

/// Calls back into the story from an observer and the error handler, recording the
/// errors.
const Caller = struct {
    story: *api.Story = undefined,
    evaluate_error: ?anyerror = null,
    reset_error: ?anyerror = null,
    save_error: ?anyerror = null,
    handled: u32 = 0,

    fn observe(context: ?*anyopaque, name: []const u8, value: Value) void {
        assert(name.len > 0 and value == .integer);
        const caller: *Caller = @ptrCast(@alignCast(context.?));
        var discarding: std.Io.Writer.Discarding = .init(&.{});
        const writer = &discarding.writer;
        if (caller.story.evaluate_function("double", &.{value}, writer)) |_| {} else |err| {
            caller.evaluate_error = err;
        }
        if (caller.story.to_json(&discarding.writer)) |_| {} else |err| caller.save_error = err;
    }

    fn on_error(context: ?*anyopaque, message: []const u8, severity: api.Severity) void {
        assert(message.len > 0 and severity == .@"error");
        const caller: *Caller = @ptrCast(@alignCast(context.?));
        caller.handled += 1;
        if (caller.story.reset_errors()) |_| {} else |err| caller.reset_error = err;
    }
};

test "an observer or the error handler can't evaluate, save or reset errors" {
    // Findings 5, 6 and 7: an observer or the error handler runs after the
    // line is written, and evaluate_function would overwrite it. A line with an error and
    // a changed observed global; the callbacks try each call.
    const gpa = std.testing.allocator;
    var program = try compile.compile_source(gpa, callbacks_source);
    defer program.deinit(gpa);
    var caller: Caller = .{};
    var story: api.Story = undefined;
    try story.init(gpa, &program, .{ .error_context = &caller, .on_error = Caller.on_error });
    defer story.deinit(gpa);
    caller.story = &story;
    try story.observe_variable("score", &caller, Caller.observe);
    // The division ends the flow before the newline, as any story error does.
    try std.testing.expectEqualStrings("Line one", (try story.cont()).get());
    try std.testing.expectEqual(@as(u32, 1), caller.handled);
    try std.testing.expectEqual(@as(?anyerror, error.Reentrant), caller.evaluate_error);
    try std.testing.expectEqual(@as(?anyerror, error.Reentrant), caller.save_error);
    try std.testing.expectEqual(@as(?anyerror, error.Reentrant), caller.reset_error);
}

test "host misuse returns errors" {
    // Finding 7: cont after an error or past the end, a choice tag or a
    // global out of range. A story with an error, then one played to its choice and end.
    const gpa = std.testing.allocator;
    var failing_program = try compile.compile_source(gpa, callbacks_source);
    defer failing_program.deinit(gpa);
    var failing: api.Story = undefined;
    try failing.init(gpa, &failing_program, .{});
    defer failing.deinit(gpa);
    try std.testing.expectError(error.StoryError, failing.cont());
    var buffer: [256]u8 = undefined;
    var message: std.Io.Writer = .fixed(&buffer);
    try failing.write_error(0, &message);
    try std.testing.expectError(error.OutOfRange, failing.write_error(1, &message));
    try std.testing.expectError(error.OutOfRange, failing.write_warning(0, &message));
    try std.testing.expectError(error.CannotContinue, failing.cont());
    var program = try compile.compile_source(gpa, choices_source);
    defer program.deinit(gpa);
    var story: api.Story = undefined;
    try story.init(gpa, &program, .{});
    defer story.deinit(gpa);
    try std.testing.expectEqualStrings("Line one\n", (try story.cont()).get());
    try std.testing.expectError(error.CannotContinue, story.cont());
    try std.testing.expectEqual(@as(u32, 1), story.current_choices_count());
    try std.testing.expectEqualStrings("t1", (try story.current_choice_tag(0, 0)).get());
    try std.testing.expectError(error.TagLimit, story.current_choice_tag(0, 1));
    try std.testing.expectError(error.ChoiceLimit, story.current_choice_tag(1, 0));
    try std.testing.expectEqualStrings("Pick", (try story.current_choice(0)).get().text);
    try std.testing.expectError(error.ChoiceLimit, story.current_choice(1));
    try std.testing.expectEqualStrings("score", story.global_variable_name(0).?);
    try std.testing.expect(story.global_variable_name(1) == null);
    try story.choose_choice_index(0);
    try std.testing.expectEqualStrings("Picked\n", (try story.cont()).get());
    try std.testing.expect(!story.can_continue());
    try std.testing.expectError(error.CannotContinue, story.cont());
}

test "evaluate_function of a knot with more parameters than arguments fails closed" {
    // A story error leaves its expression's values on the evaluation stack, as in ink; a
    // knot evaluated with too few arguments popped them as its parameters, below its own
    // frame. ink returns null with the values gone; inkz asserted, and now reports a story
    // error at the pop and leaves the values alone (found by the swarm's host target with
    // P18.6's knots with parameters).
    const gpa = std.testing.allocator;
    const source =
        \\VAR a = 0
        \\Hello
        \\~ a = 1 + divide(1)
        \\-> DONE
        \\== knot(x) ==
        \\Knot {x}
        \\-> DONE
        \\== function divide(n) ==
        \\~ return n / 0
        \\
    ;
    var program = try compile.compile_source(gpa, source);
    defer program.deinit(gpa);
    const story = try start(gpa, &program, .{});
    defer stop(gpa, story);
    try std.testing.expectEqualStrings("Hello\n", (try story.cont()).get());
    try std.testing.expectError(error.StoryError, story.cont());
    const left = story.state.evaluation.count;
    try std.testing.expect(left > 0);
    try story.reset_errors();
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try std.testing.expectError(
        error.StoryError,
        story.evaluate_function("knot", &.{}, &text.writer),
    );
    try std.testing.expect(!story.failed);
    try std.testing.expect(!story.can_continue());
    try std.testing.expectEqual(@as(u32, 1), story.state.call_stack.depth());
    try std.testing.expectEqual(left, story.state.evaluation.count);
}

const Popper = struct {
    result: ?anyerror = null,

    fn call(context: ?*anyopaque, story: *api.Story, arguments: []const Value) anyerror!Value {
        assert(arguments.len == 2);
        const popper: *Popper = @ptrCast(@alignCast(context.?));
        var buffer: [64]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        _ = evaluate.evaluate_function(story, "knot", &.{}, &writer) catch |err| {
            popper.result = err;
            return .null;
        };
        return .null;
    }
};

test "evaluate_function from an external can't pop the external's arguments" {
    // P17 review: inside a bound external its arguments sit just below the evaluation's
    // frame. A knot with more parameters than arguments popped them, the story error
    // returned without the stack's height back, the external swallowed it and call_bound
    // asserted on fewer values than it pushed (in ReleaseFast it raised the count over
    // stale slots). Now the pop below the frame is the story error.
    const gpa = std.testing.allocator;
    const source =
        \\EXTERNAL ext(a, b)
        \\Hello
        \\~ ext(5, 6)
        \\World
        \\-> DONE
        \\== knot(x, y, z) ==
        \\Knot {x}
        \\-> DONE
        \\
    ;
    var program = try compile.compile_source(gpa, source);
    defer program.deinit(gpa);
    const story = try start(gpa, &program, .{});
    defer stop(gpa, story);
    var popper: Popper = .{};
    try story.bind_external_function("ext", .{ .lookahead_safe = true }, &popper, Popper.call);
    // The newline lookahead runs the external, so the first line already fails.
    try std.testing.expectError(error.StoryError, story.cont());
    try std.testing.expectEqual(@as(?anyerror, error.StoryError), popper.result);
    try std.testing.expect(!story.failed);
    try std.testing.expectEqual(@as(u32, 0), story.evaluation_floor);
    // The flow ended at the pop, so the outer line runs out of content too.
    try std.testing.expectEqual(@as(u32, 2), story.error_count());
    var message: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&message);
    try story.write_error(0, &writer);
    const expected = "trying to pop too many objects";
    try std.testing.expect(std.mem.endsWith(u8, writer.buffered(), expected));
}
