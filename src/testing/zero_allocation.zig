//! The zero-allocation gate (plan P5.11): after `Story.init`, the new runtime allocates
//! nothing. Structurally, no field of the story or its state is an allocator; at run time,
//! every ground-truth case runs cont, choose_choice_index, set_variable, switch_flow and
//! evaluate_function with a counting allocator behind init, and the count doesn't move.

const std = @import("std");
const assert = std.debug.assert;
const ink_json = @import("../core/ink_json.zig");
const CountingAllocator = @import("../core/counting_allocator.zig").CountingAllocator;
const story_module = @import("../vm/story.zig");
const state_module = @import("../vm/state.zig");
const flows = @import("../vm/flows.zig");
const evaluate = @import("../vm/evaluate.zig");
const cases = @import("cases.zig");
const ground_truth_test = @import("ground_truth_test.zig");
const Story = story_module.Story;

/// No field of `T` is an allocator (the types the story keeps after init).
fn has_no_allocator(comptime T: type) bool {
    assert(@typeInfo(T) == .@"struct");
    assert(@sizeOf(std.mem.Allocator) > 0);
    for (@typeInfo(T).@"struct".field_types) |Field| {
        if (Field == std.mem.Allocator) return false;
    }
    return true;
}

comptime {
    assert(has_no_allocator(Story));
    assert(has_no_allocator(state_module.State));
}

fn ignore_error(
    context: ?*anyopaque,
    message: []const u8,
    severity: state_module.Diagnostic.Severity,
) void {
    assert(context == null);
    assert(message.len > 0 or severity == .warning);
}

fn noop_external(
    context: ?*anyopaque,
    story: *Story,
    arguments: []const story_module.HostValue,
) anyerror!story_module.HostValue {
    assert(context == null);
    assert(arguments.len <= story_module.external_arguments_max and story.callback_depth > 0);
    return .{ .integer = 0 };
}

/// Plays `story` for a few turns with every mutating call the gate names.
fn exercise(story: *Story) !void {
    assert(story.callback_depth == 0);
    assert(story.state.memory.len > 0);
    for (story.program.externals) |external| {
        const name = story.program.strings.get(external.name);
        story.bind_external_function(name, noop_external, null, true) catch {};
    }
    story.on_error = ignore_error;
    var turn: u32 = 0;
    while (turn < 20) : (turn += 1) {
        var lines: u32 = 0;
        while (story.can_continue() and lines < 200) : (lines += 1) {
            _ = story.cont() catch |err| switch (err) {
                error.StoryError, error.ExternalFunctionFailed => break,
                else => return err,
            };
        }
        for (story.program.globals, 0..) |global, slot| {
            const value = story.state.globals[slot];
            if (value == .null or value == .variable_pointer) continue;
            try story.set_variable(story.program.strings.get(global.name), value);
        }
        try flows.switch_flow(&story.state, "gate");
        try flows.switch_flow(&story.state, flows.default_name);
        if (story.visible_choices_count() == 0) break;
        try story.choose_choice_index(0);
    }
}

test "the new runtime allocates nothing after init, on every ground-truth case" {
    // Goal: P5.11. Method: init each case's story through a counting allocator, then play
    // it with cont, choices, set_variable and flow switches; growths must not change.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var checked: u32 = 0;
    for (try ground_truth_test.collect_cases(arena, io)) |id| {
        const path = try std.fmt.allocPrint(arena, "{s}/{s}.ink.json", .{
            cases.cases_directory,
            id,
        });
        const json = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 << 20));
        var program = ink_json.load(arena, json) catch continue;
        var counting = CountingAllocator.init(std.testing.allocator);
        var story: Story = undefined;
        story.init(counting.allocator(), &program, .{}) catch continue;
        defer story.deinit(counting.allocator());
        const before = counting.growths();
        exercise(&story) catch |err| switch (err) {
            error.StoryError, error.StepLimit => {},
            else => return err,
        };
        std.testing.expectEqual(before, counting.growths()) catch |err| {
            std.debug.print("case {s} allocated\n", .{id});
            return err;
        };
        checked += 1;
    }
    try std.testing.expect(checked > 150);
}

test "evaluate_function allocates nothing" {
    // Goal: P5.11 for evaluate_function. Method: the side-effects case's `add`, twice.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = cases.cases_directory ++ "/audit/evaluate_function_side_effects.ink.json";
    const json = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, arena, .limited(1 << 20));
    var program = try ink_json.load(arena, json);
    var counting = CountingAllocator.init(std.testing.allocator);
    var story: Story = undefined;
    try story.init(counting.allocator(), &program, .{});
    defer story.deinit(counting.allocator());
    const before = counting.growths();
    _ = try story.cont();
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const first = try evaluate.evaluate_function(&story, "add", &.{.{ .integer = 3 }}, &writer);
    const second = try evaluate.evaluate_function(&story, "add", &.{.{ .integer = 4 }}, &writer);
    try std.testing.expectEqual(@as(i32, 3), first.integer);
    try std.testing.expectEqual(@as(i32, 7), second.integer);
    try std.testing.expectEqual(before, counting.growths());
}
