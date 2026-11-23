//! ink's EvaluateFunction: runs an ink function on the live state.
//! The output stream is set aside, a `function_evaluation_from_game` frame is pushed, and
//! the Continue loop runs until the function ends; every other side effect (globals, visit
//! counts, the random state) persists. It may be called from an external function, up to
//! `evaluate_depth_max` deep.

const std = @import("std");
const assert = std.debug.assert;
const story_module = @import("story.zig");
const output_module = @import("output.zig");
const state_module = @import("state.zig");
const ops = @import("ops.zig");
const vm = @import("vm.zig");
const Value = @import("value.zig").Value;
const Story = story_module.Story;
const HostValue = story_module.HostValue;
const Item = output_module.Item;
const call_stack_module = @import("call_stack.zig");
const ContainerIndex = @import("../core/index.zig").ContainerIndex;

pub const Error = story_module.Error || error{
    /// ink's "Function doesn't exist".
    FunctionNotFound,
    EvaluateDepthLimit,
    /// `Limits.output_stash_bytes_max` has no room to set the output aside.
    OutputStashLimit,
    /// ink's "Expected external function evaluation to be complete".
    EvaluationNotComplete,
};

/// Calls the ink function `name` with `arguments`, writing its text to `text_writer`, and
/// returns its result (a divert target comes back as its path, as in ink). It fails
/// closed: a failure before the function runs or a full `text_writer` leave the state as
/// it was before the call (with side effects so far kept); a story error ends the flow, as
/// in `cont`; a limit or host error in the middle of a step fails the story
/// (`Story.failed`).
pub fn evaluate_function(
    story: *Story,
    name: []const u8,
    arguments: []const HostValue,
    text_writer: *std.Io.Writer,
) Error!HostValue {
    assert(name.len > 0);
    story_module.invalidate_views(story);
    if (!story_module.may_evaluate(story)) return error.Reentrant;
    if (story.failed) return error.StoryFailed;
    // Kept errors stop the story from continuing, so the function couldn't run.
    if (story.state.has_error()) return error.StoryError;
    if (story.events.on_evaluate_function) |event| {
        story.callback_depth += 1;
        defer story.callback_depth -= 1;
        event(story.events.context, name, arguments);
    }
    const program = story.program;
    const container = program.named_child(program.root_container(), name) orelse
        return error.FunctionNotFound;
    const depth_max = story.state.limits.evaluate_depth_max;
    if (story.evaluate_depth == depth_max) return error.EvaluateDepthLimit;
    const before = try begin_evaluation(story, container, arguments);
    const text_start = text_writer.end;
    var stepping = false;
    const result = run_evaluation(story, before, text_writer, &stepping) catch |err| {
        abandon_evaluation(story, before, err != error.StoryError and stepping);
        assert(story.evaluation_floor == before.evaluation_floor);
        return err;
    };
    assert(story.evaluation_floor == before.evaluation_floor);
    if (story.events.on_complete_evaluate_function) |event| {
        // The text is what the writer still buffers (all of it for a fixed or allocating
        // writer).
        const buffered = text_writer.buffered();
        const text = if (text_start <= buffered.len) buffered[text_start..] else "";
        // The host's arguments may be heap strings the run has moved; the pinned copies
        // below the frame were roots all along.
        var pinned: [story_module.external_arguments_max]HostValue = undefined;
        const state = &story.state;
        assert(state.evaluation.count == before.evaluation_height + arguments.len);
        const values = state.evaluation.slice()[before.evaluation_height..];
        for (values, pinned[0..arguments.len]) |value, *host| host.* = ops.host_value(story, value);
        state.evaluation.count = before.evaluation_height;
        story.callback_depth += 1;
        defer story.callback_depth -= 1;
        event(story.events.context, name, pinned[0..arguments.len], text, result);
    }
    assert(story.state.evaluation.count == before.evaluation_height);
    return result;
}

/// The state before an evaluation, to go back to if it fails.
const Before = struct {
    call_stack: call_stack_module.CallStack.Mark,
    evaluation_height: u32,
    evaluation_floor: u32,
};

/// ink's StartFunctionEvaluationFromGame: the output set aside, the frame and the
/// arguments pushed. On failure the state is as before (but for heap garbage).
fn begin_evaluation(
    story: *Story,
    container: ContainerIndex,
    arguments: []const HostValue,
) Error!Before {
    var values: [story_module.external_arguments_max]Value = undefined;
    if (arguments.len > values.len) return error.EvaluationLimit;
    // First, since storing strings may compact the heap; nothing after this allocates.
    try ops.values_of_host(story, arguments, values[0..arguments.len]);
    const state = &story.state;
    const before: Before = .{
        .call_stack = state.call_stack.mark(),
        .evaluation_height = state.evaluation.count,
        .evaluation_floor = story.evaluation_floor,
    };
    // With on_complete_evaluate_function, a second copy of the arguments is pinned below
    // the frame, so the event gets them valid however the heap moved.
    const pins_count: u32 = if (story.events.on_complete_evaluate_function != null)
        @intCast(arguments.len)
    else
        0;
    if (arguments.len + pins_count > state.evaluation.capacity() - before.evaluation_height) {
        return error.EvaluationLimit;
    }
    try stash_output(story);
    errdefer unstash_output(story);
    state.output.clear();
    const frame_height = before.evaluation_height + pins_count;
    state.call_stack.push(.function_evaluation_from_game, frame_height, 0) catch
        return error.FrameLimit;
    state.call_stack.current_frame().pointer = .start_of(container);
    state.evaluation.push_slice(values[0..pins_count]) catch unreachable;
    state.evaluation.push_slice(values[0..arguments.len]) catch unreachable;
    // The function's parameters pop its arguments, never what lies below its frame.
    story.evaluation_floor = frame_height;
    assert(state.call_stack.frames.count == before.call_stack.frames + 1);
    return before;
}

/// The Continue loop until the function ends, then its result. `stepping` is true while a
/// line runs.
fn run_evaluation(
    story: *Story,
    before: Before,
    text_writer: *std.Io.Writer,
    stepping: *bool,
) Error!HostValue {
    assert(story.state.call_stack.depth() > 1);
    const callback_depth = story.callback_depth;
    const external_callback_depth = story.external_callback_depth;
    story.callback_depth = 0;
    story.external_callback_depth = 0;
    story.evaluate_depth += 1;
    defer {
        story.evaluate_depth -= 1;
        story.callback_depth = callback_depth;
        story.external_callback_depth = external_callback_depth;
    }
    while (story.can_continue()) {
        stepping.* = true;
        const line = try story_module.next_line(story);
        stepping.* = false;
        text_writer.writeAll(line) catch return error.OutputLimit;
    }
    const result = try complete_function_evaluation(story);
    story.evaluation_floor = before.evaluation_floor;
    unstash_output(story);
    return result;
}

/// After a failed run: the output set aside comes back. A story error has already ended
/// the flow (`ops.fail` force-ends it, as after any story error), so nothing of the
/// evaluation is left on the call stack. Otherwise, between steps (a full writer, an
/// unfinished evaluation) the evaluation's frames, threads and values are dropped and the
/// story goes on from before the call. A step left half done fails the story closed, as
/// `Story.fail_step` does.
fn abandon_evaluation(story: *Story, before: Before, half_done: bool) void {
    assert(story.state.output_stashes_count > 0);
    unstash_output(story);
    const state = &story.state;
    // Nothing below the frame was popped (`Story.evaluation_floor`).
    assert(state.evaluation.count >= story.evaluation_floor);
    assert(story.evaluation_floor >= before.evaluation_height);
    story.evaluation_floor = before.evaluation_floor;
    state.evaluation.count = before.evaluation_height;
    if (half_done) {
        story.failed = true;
        return;
    }
    const ended = state.call_stack.depth() == 1 and vm.current_pointer(story).is_null();
    if (ended) return;
    if (!state.call_stack.unwind(before.call_stack, .function_evaluation_from_game)) {
        story.failed = true;
        return;
    }
    assert(state.call_stack.frames.count == before.call_stack.frames);
}

/// ink's CompleteFunctionEvaluationFromGame: the first value above the frame's height is
/// the result; the rest is dropped.
fn complete_function_evaluation(story: *Story) Error!HostValue {
    const state = &story.state;
    const frame = state.call_stack.current_frame();
    if (frame.kind != .function_evaluation_from_game) return error.EvaluationNotComplete;
    const height = frame.evaluation_height;
    // A knot or function with more parameters than the host passed can't pop below its
    // frame (`Story.evaluation_floor`): the pop is a story error, ink's "trying to pop too
    // many objects".
    assert(height == story.evaluation_floor);
    assert(height <= state.evaluation.count);
    const returned: ?Value = if (state.evaluation.count > height)
        state.evaluation.buffer[height]
    else
        null;
    state.evaluation.count = height;
    ops.pop_call_stack(story, .function_evaluation_from_game) catch
        return error.EvaluationNotComplete;
    assert(state.evaluation.count == height);
    const value = returned orelse return .null;
    return switch (value) {
        .divert_target => |target| .{ .string = story_module.path_of(story, target) },
        else => ops.host_value(story, value),
    };
}

fn stash_output(story: *Story) Error!void {
    const state = &story.state;
    assert(state.output_stashes_count <= state_module.output_stashes_max);
    assert(state.output_stash.len > 0);
    if (state.output_stashes_count == state_module.output_stashes_max) {
        return error.EvaluateDepthLimit;
    }
    const first = stashed_words(state);
    const items = state.output.items.slice();
    const marks = state.output.string_marks.slice();
    const words: u32 = @intCast(items.len * 3 + marks.len);
    if (first + words > state.output_stash.len) return error.OutputStashLimit;
    const target = state.output_stash[first..][0..words];
    @memcpy(target[0 .. items.len * 3], std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(items)));
    @memcpy(target[items.len * 3 ..], marks);
    state.output_stashes[state.output_stashes_count] = .{
        .first = first,
        .items = @intCast(items.len),
        .marks = @intCast(marks.len),
    };
    state.output_stashes_count += 1;
    state.peaks.output_stash_words = @max(state.peaks.output_stash_words, first + words);
}

fn stashed_words(state: *const state_module.State) u32 {
    var words: u32 = 0;
    for (state.output_stashes[0..state.output_stashes_count]) |stash| {
        words += stash.items * 3 + stash.marks;
    }
    assert(words <= state.output_stash.len);
    return words;
}

/// ink's ResetOutput(outputStreamBefore).
fn unstash_output(story: *Story) void {
    const state = &story.state;
    assert(state.output_stashes_count > 0);
    state.output_stashes_count -= 1;
    const stash = state.output_stashes[state.output_stashes_count];
    const words = state.output_stash[stash.first..][0 .. stash.items * 3 + stash.marks];
    const item_bytes = std.mem.sliceAsBytes(words[0 .. stash.items * 3]);
    const items: []const Item = @alignCast(std.mem.bytesAsSlice(Item, item_bytes));
    state.output.clear();
    state.output.items.push_slice(items) catch unreachable;
    state.output.string_marks.push_slice(words[stash.items * 3 ..]) catch unreachable;
}

const ProgramBuilder = @import("../core/program_builder.zig").ProgramBuilder;
const Program = @import("../core/program.zig").Program;
const instruction_module = @import("../core/instruction.zig");

/// The root calls external `ext`; function `inner` calls it too and returns its result.
fn external_program(gpa: std.mem.Allocator) !Program {
    var builder = try ProgramBuilder.init(gpa);
    defer builder.deinit();
    const external = try builder.external("ext");
    const call = try builder.extra.add(gpa, instruction_module.ExternalCall{
        .external = external,
        .arguments_count = 0,
        .flags = .{ .conditional = false },
    });
    _ = try builder.begin_container(.{});
    inline for (.{ true, false }) |is_root| {
        if (!is_root) _ = try builder.begin_container(.{ .name = "inner", .named_only = true });
        try builder.add(.eval_start, {});
        try builder.add(.call_external, @fromBackingInt(call));
        if (is_root) try builder.add(.pop, {});
        try builder.add(.eval_end, {});
        try builder.add(if (is_root) .done else .function_return, {});
        if (!is_root) try builder.end_container();
    }
    try builder.end_container();
    return try builder.finish();
}

const Probe = struct {
    calls: u32 = 0,
    /// Call `cont` from the callback instead of evaluating `inner`.
    reenter: bool = false,
    reentrant_error: bool = false,

    fn call(context: ?*anyopaque, story: *Story, _: []const HostValue) anyerror!HostValue {
        const probe: *Probe = @ptrCast(@alignCast(context.?));
        assert(story.callback_depth > 0);
        probe.calls += 1;
        if (probe.reenter) {
            _ = story.cont() catch |err| {
                probe.reentrant_error = err == error.Reentrant;
                return .null;
            };
            return .null;
        }
        var discarding: std.Io.Writer.Discarding = .init(&.{});
        return evaluate_function(story, "inner", &.{}, &discarding.writer);
    }
};

test "evaluate_function nests from an external up to evaluate_depth_max" {
    // An external may evaluate an ink function, which may call the external
    // again, until evaluate_depth_max. An external that always evaluates `inner`.
    const gpa = std.testing.allocator;
    var program = try external_program(gpa);
    defer program.deinit(gpa);
    var story: Story = undefined;
    try story.init(gpa, &program, .{ .limits = .{ .evaluate_depth_max = 3 } });
    defer story.deinit(gpa);
    var probe: Probe = .{};
    try story.bind_external_function("ext", .{}, &probe, Probe.call);
    try std.testing.expectError(error.ExternalFunctionFailed, story.cont());
    // The root's call and one per nested evaluation; the fourth evaluation is refused.
    try std.testing.expectEqual(@as(u32, 4), probe.calls);
    try std.testing.expectEqual(@as(u32, 0), story.evaluate_depth);
}

test "other mutating calls from a callback are reentrant" {
    // Cont from inside an external returns Reentrant (ink would corrupt its
    // state). An external that calls cont.
    const gpa = std.testing.allocator;
    var program = try external_program(gpa);
    defer program.deinit(gpa);
    var story: Story = undefined;
    try story.init(gpa, &program, .{});
    defer story.deinit(gpa);
    var probe: Probe = .{ .reenter = true };
    try story.bind_external_function("ext", .{}, &probe, Probe.call);
    _ = try story.cont();
    try std.testing.expect(probe.reentrant_error);
    try std.testing.expectEqual(@as(u32, 0), story.callback_depth);
}
