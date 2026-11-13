//! ink's EvaluateFunction (plan §4.7, S1, P5.8): runs an ink function on the live state.
//! The output stream is set aside, a `function_evaluation_from_game` frame is pushed, and
//! the Continue loop runs until the function ends; every other side effect (globals, visit
//! counts, the random state) persists. It may be called from an external function, up to
//! `evaluate_depth_max` deep.

const std = @import("std");
const assert = std.debug.assert;
const story_module = @import("story.zig");
const output_module = @import("output.zig");
const state_module = @import("state.zig");
const flows = @import("flows.zig");
const ops = @import("ops.zig");
const vm = @import("vm.zig");
const Value = @import("value.zig").Value;
const Story = story_module.Story;
const HostValue = story_module.HostValue;
const Item = output_module.Item;

pub const Error = story_module.Error || error{
    /// ink's "Function doesn't exist".
    FunctionNotFound,
    EvaluateDepthLimit,
    /// The parking region has no room to set the output aside.
    FlowParkingLimit,
    /// ink's "Expected external function evaluation to be complete".
    EvaluationNotComplete,
};

/// Calls the ink function `name` with `arguments`, writing its text to `text_writer`, and
/// returns its result (a divert target comes back as its path, as in ink).
pub fn evaluate_function(
    story: *Story,
    name: []const u8,
    arguments: []const HostValue,
    text_writer: *std.Io.Writer,
) Error!HostValue {
    assert(name.len > 0);
    if (story.failed) return error.StoryFailed;
    if (story.events.on_evaluate_function) |event| {
        story.callback_depth += 1;
        defer story.callback_depth -= 1;
        event(story.events.context, name, arguments);
    }
    const program = story.program;
    const container = program.named_child(program.root_container(), name) orelse
        return error.FunctionNotFound;
    assert(container.to_int() < program.containers.len);
    const depth_max = story.state.limits.evaluate_depth_max;
    if (story.evaluate_depth == depth_max) return error.EvaluateDepthLimit;
    assert(story.evaluate_depth < depth_max);
    try stash_output(story);
    var stashed = true;
    errdefer if (stashed) unstash_output(story);
    story.state.output.clear();
    const state = &story.state;
    // ink's StartFunctionEvaluationFromGame.
    state.call_stack.push(.function_evaluation_from_game, state.evaluation.count, 0) catch
        return error.FrameLimit;
    state.call_stack.current_frame().pointer = .start_of(container);
    for (arguments) |argument| try vm.push_evaluation(
        story,
        try ops.value_of_host(story, argument),
    );
    const callback_depth = story.callback_depth;
    story.callback_depth = 0;
    story.evaluate_depth += 1;
    defer {
        story.evaluate_depth -= 1;
        story.callback_depth = callback_depth;
    }
    const text_start = text_writer.end;
    while (story.can_continue()) {
        const line = try story.next_line();
        text_writer.writeAll(line) catch return error.OutputLimit;
    }
    stashed = false;
    unstash_output(story);
    const result = try complete_function_evaluation(story);
    if (story.events.on_complete_evaluate_function) |event| {
        // The text is what the writer still buffers (all of it for a fixed or allocating
        // writer).
        const buffered = text_writer.buffered();
        const text = if (text_start <= buffered.len) buffered[text_start..] else "";
        story.callback_depth += 1;
        defer story.callback_depth -= 1;
        event(story.events.context, name, arguments, text, result);
    }
    return result;
}

/// ink's CompleteFunctionEvaluationFromGame: the first value above the frame's height is
/// the result; the rest is dropped.
fn complete_function_evaluation(story: *Story) Error!HostValue {
    const state = &story.state;
    const frame = state.call_stack.current_frame();
    if (frame.kind != .function_evaluation_from_game) return error.EvaluationNotComplete;
    const height = frame.evaluation_height;
    assert(height <= state.evaluation.count);
    assert(state.call_stack.depth() > 1);
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
        .divert_target => |target| .{ .string = story.path_of(target) },
        else => ops.host_value(story, value),
    };
}

fn stash_output(story: *Story) Error!void {
    const state = &story.state;
    assert(state.output_stashes_count <= state_module.output_stashes_max);
    assert(state.parking.len > 0);
    if (state.output_stashes_count == state_module.output_stashes_max) {
        return error.EvaluateDepthLimit;
    }
    const first = flows.parking_used(state) + stashed_words(state);
    const items = state.output.items.slice();
    const marks = state.output.string_marks.slice();
    const words: u32 = @intCast(items.len * 3 + marks.len);
    if (first + words > state.parking.len) return error.FlowParkingLimit;
    const target = state.parking[first..][0..words];
    @memcpy(target[0 .. items.len * 3], std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(items)));
    @memcpy(target[items.len * 3 ..], marks);
    state.output_stashes[state.output_stashes_count] = .{
        .first = first,
        .items = @intCast(items.len),
        .marks = @intCast(marks.len),
    };
    state.output_stashes_count += 1;
}

fn stashed_words(state: *const state_module.State) u32 {
    assert(state.output_stashes_count <= state_module.output_stashes_max);
    var words: u32 = 0;
    for (state.output_stashes[0..state.output_stashes_count]) |stash| {
        words += stash.items * 3 + stash.marks;
    }
    assert(words <= state.parking.len);
    return words;
}

/// ink's ResetOutput(outputStreamBefore).
fn unstash_output(story: *Story) void {
    const state = &story.state;
    assert(state.output_stashes_count > 0);
    state.output_stashes_count -= 1;
    const stash = state.output_stashes[state.output_stashes_count];
    const words = state.parking[stash.first..][0 .. stash.items * 3 + stash.marks];
    const item_bytes = std.mem.sliceAsBytes(words[0 .. stash.items * 3]);
    const items: []const Item = @alignCast(std.mem.bytesAsSlice(Item, item_bytes));
    assert(items.len == stash.items);
    state.output.clear();
    state.output.items.push_slice(items) catch unreachable;
    state.output.string_marks.push_slice(words[stash.items * 3 ..]) catch unreachable;
}

const ProgramBuilder = @import("../core/program_builder.zig").ProgramBuilder;
const Program = @import("../core/program.zig").Program;
const instruction_module = @import("../core/instruction.zig");

/// The root calls external `ext`; function `inner` calls it too and returns its result.
fn external_program(gpa: std.mem.Allocator) !Program {
    assert(@sizeOf(instruction_module.ExternalCall) > 0);
    var builder = try ProgramBuilder.init(gpa);
    defer builder.deinit();
    const external = try builder.external("ext");
    const call = try builder.extra.add(gpa, instruction_module.ExternalCall{
        .external = external,
        .arguments_count = 0,
        .conditional = false,
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
    const program = try builder.finish();
    assert(program.externals.len == 1);
    return program;
}

const Probe = struct {
    calls: u32 = 0,
    /// Call `cont` from the callback instead of evaluating `inner`.
    reenter: bool = false,
    reentrant_error: bool = false,

    fn call(context: ?*anyopaque, story: *Story, arguments: []const HostValue) anyerror!HostValue {
        const probe: *Probe = @ptrCast(@alignCast(context.?));
        assert(arguments.len == 0);
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
    // Goal: P5.8; an external may evaluate an ink function, which may call the external
    // again, until evaluate_depth_max. Method: an external that always evaluates `inner`.
    const gpa = std.testing.allocator;
    var program = try external_program(gpa);
    defer program.deinit(gpa);
    var story: Story = undefined;
    try story.init(gpa, &program, .{ .evaluate_depth_max = 3 });
    defer story.deinit(gpa);
    var probe: Probe = .{};
    try story.bind_external_function("ext", Probe.call, &probe, true);
    try std.testing.expectError(error.ExternalFunctionFailed, story.cont());
    // The root's call and one per nested evaluation; the fourth evaluation is refused.
    try std.testing.expectEqual(@as(u32, 4), probe.calls);
    try std.testing.expectEqual(@as(u32, 0), story.evaluate_depth);
}

test "other mutating calls from a callback are reentrant" {
    // Goal: P5.8; cont from inside an external returns Reentrant (ink would corrupt its
    // state). Method: an external that calls cont.
    const gpa = std.testing.allocator;
    var program = try external_program(gpa);
    defer program.deinit(gpa);
    var story: Story = undefined;
    try story.init(gpa, &program, .{});
    defer story.deinit(gpa);
    var probe: Probe = .{ .reenter = true };
    try story.bind_external_function("ext", Probe.call, &probe, true);
    _ = try story.cont();
    try std.testing.expect(probe.reentrant_error);
    try std.testing.expectEqual(@as(u32, 0), story.callback_depth);
}
