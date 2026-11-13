//! The Story calls that take ink path strings (plan §4.7): ChoosePathString,
//! VisitCountAtPathString, TagsForContentAtPath and globalTags. Paths are resolved with
//! `core/path.zig` against the program, off the hot path.

const std = @import("std");
const assert = std.debug.assert;
const path_module = @import("../core/path.zig");
const index = @import("../core/index.zig");
const container_module = @import("../core/container.zig");
const story_module = @import("story.zig");
const ops = @import("ops.zig");
const call_stack_module = @import("call_stack.zig");
const Story = story_module.Story;
const ContainerIndex = index.ContainerIndex;
const Pointer = call_stack_module.Pointer;

pub const PathError = error{
    /// ink's "Failed to find content at path".
    PathNotFound,
    /// ink's exception for ChoosePathString without a reset while a function runs.
    ChoosePathInFunction,
};

/// ink's PointerAtPath: a path to a container starts at its first item; a path ending in an
/// index points at that item. Approximate matches are not followed.
pub fn pointer_at_path(story: *const Story, text: []const u8) PathError!Pointer {
    assert(text.len > 0);
    const limit = story.state.limits.path_components_max;
    const path = path_module.Path.parse(text, limit) catch return error.PathNotFound;
    const origin: path_module.Origin = .{ .container = story.program.root_container() };
    const target = path_module.resolve(story.program, origin, path) catch return error.PathNotFound;
    if (target.approximate) return error.PathNotFound;
    const position = target.content_index orelse 0;
    const pointer: Pointer = .{ .container = target.container, .index = position };
    assert(pointer.container.to_int() < story.program.containers.len);
    return pointer;
}

/// ink's ChoosePathString (without arguments): with `reset_callstack`, the flow is ended
/// first (ink's ResetCallstack); the turn index advances as when choosing.
pub fn choose_path_string(
    story: *Story,
    text: []const u8,
    reset_callstack: bool,
    arguments: []const story_module.HostValue,
) (PathError || story_module.Error)!void {
    assert(text.len > 0);
    if (story.callback_depth > 0) return error.Reentrant;
    if (story.failed) return error.StoryFailed;
    if (story.events.on_choose_path_string) |event| {
        story.callback_depth += 1;
        defer story.callback_depth -= 1;
        event(story.events.context, text, arguments);
    }
    const target = try pointer_at_path(story, text);
    if (reset_callstack) {
        ops.force_end(story);
    } else if (story.state.call_stack.current_frame().kind == .function) {
        return error.ChoosePathInFunction;
    }
    // ink's PassArgumentsToEvaluationStack, for a knot with parameters.
    for (arguments) |argument| {
        const value = try ops.value_of_host(story, argument);
        story.state.evaluation.push(value) catch return error.EvaluationLimit;
    }
    try story.choose_pointer(target, true);
    assert(story.state.choices.count() == 0);
}

/// ink's VisitCountAtPathString: counts are kept by exact container path, so a path that
/// isn't one (or isn't counted) has 0.
pub fn visit_count_at_path_string(story: *const Story, text: []const u8) u32 {
    assert(text.len > 0);
    const id = story.program.strings.find(text) orelse return 0;
    const table = story.program.table();
    var position: u32 = 0;
    while (position < table.count()) : (position += 1) {
        const info = table.get(.from_int(position));
        if (info.path != id) continue;
        if (info.count_slot == container_module.no_count_slot) return 0;
        return story.state.visit_counts[info.count_slot];
    }
    assert(position == table.count());
    return 0;
}

/// ink's TagsAtStartOfFlowContainerWithPathString: the plain-text tags at the start of the
/// container at `text`, each passed to `sink.tag(text)`.
pub fn tags_at_path(story: *const Story, text: []const u8, sink: anytype) !void {
    assert(@typeInfo(@TypeOf(sink)) == .pointer);
    assert(text.len > 0);
    const pointer = try pointer_at_path(story, text);
    try tags_at_start(story, pointer.container, sink);
}

/// ink's globalTags: the tags at the start of the story.
pub fn global_tags(story: *const Story, sink: anytype) !void {
    assert(@typeInfo(@TypeOf(sink)) == .pointer);
    assert(story.program.containers.len > 0);
    try tags_at_start(story, story.program.root_container(), sink);
}

/// Descends into first-item containers, then reads `#` text `/#` groups until other
/// content.
fn tags_at_start(story: *const Story, start: ContainerIndex, sink: anytype) !void {
    var container = start;
    var depth: u32 = 0;
    while (story.program.content_count(container) > 0) : (depth += 1) {
        assert(depth <= story.program.containers.len);
        container = story.program.container_at(container, 0) orelse break;
    }
    var in_tag = false;
    const count = story.program.content_count(container);
    var position: u32 = 0;
    while (position < count) : (position += 1) {
        const instruction = story.program.instruction_at(container, position);
        switch (instruction.opcode) {
            .tag_start => in_tag = true,
            .tag_end => in_tag = false,
            .text => {
                if (!in_tag) return;
                try sink.tag(story.program.strings.get(instruction.get(.text)));
            },
            else => if (in_tag) return error.TagNotText else return,
        }
    }
    assert(position == count);
}
