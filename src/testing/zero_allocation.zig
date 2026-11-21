//! The zero-allocation gate: after `Story.init`, the runtime allocates nothing.
//! Structurally, no field of the story or its state is an allocator; at run time, every
//! ground-truth case runs cont, choose_choice_index, set_variable, switch_flow and
//! evaluate_function with a counting allocator behind init, and the count doesn't move.

const std = @import("std");
const assert = std.debug.assert;
const ink_json = @import("../core/ink_json.zig");
const CountingAllocator = @import("../core/counting_allocator.zig").CountingAllocator;
const Story = @import("../runtime/story.zig").Story;
const state_module = @import("../runtime/state.zig");
const flows = @import("../runtime/flows.zig");
const evaluate = @import("../runtime/evaluate.zig");
const save = @import("../runtime/save.zig");
const load = @import("../runtime/load.zig");
const cases = @import("cases.zig");
const support = @import("support.zig");

/// No field of `T` is an allocator (the types the story keeps after init).
fn has_no_allocator(comptime T: type) bool {
    assert(@typeInfo(T) == .@"struct");
    for (@typeInfo(T).@"struct".field_types) |Field| {
        if (Field == std.mem.Allocator) return false;
    }
    return true;
}

comptime {
    assert(has_no_allocator(Story));
    assert(has_no_allocator(state_module.State));
}

/// Plays `story` for a few turns with every mutating call the gate names.
fn exercise(story: *Story) !void {
    assert(story.callback_depth == 0);
    support.quiet(story);
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

test "the runtime allocates nothing after init, on every ground-truth case" {
    // Init each case's story through a counting allocator, then play
    // it with cont, choices, set_variable and flow switches; growths must not change.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var checked: u32 = 0;
    for (try cases.ids(arena, io)) |id| {
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
    // For evaluate_function: the side-effects case's `add`, twice.
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

test "load_json allocates nothing" {
    // For load_json: crime_scene played a few turns and saved to a
    // fixed buffer; loading that save into the story, twice, leaves the growths unchanged.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = cases.cases_directory ++ "/crime_scene.ink.json";
    const json = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, arena, .limited(1 << 20));
    var program = try ink_json.load(arena, json);
    var counting = CountingAllocator.init(std.testing.allocator);
    var story: Story = undefined;
    try story.init(counting.allocator(), &program, .{});
    defer story.deinit(counting.allocator());
    try exercise(&story);
    const buffer = try arena.alloc(u8, 1 << 20);
    var writer: std.Io.Writer = .fixed(buffer);
    try save.to_json(&story, &writer);
    const saved = writer.buffered();
    const before = counting.growths();
    try load.load_json(&story, saved);
    try load.load_json(&story, saved);
    try std.testing.expectEqual(before, counting.growths());
}

const compile = @import("../compiler/compile.zig");
const HostValue = @import("../runtime/story.zig").HostValue;

fn twice(context: ?*anyopaque, _: *Story, arguments: []const HostValue) anyerror!HostValue {
    assert(context == null);
    return .{ .integer = arguments[0].integer * 2 };
}

test "Story.init makes one allocation, bindings included, and binding allocates nothing" {
    // A story with two externals under a counting allocator: init allocates exactly
    // Limits.bytes_total of its shape (externals counted) once; binding, rebinding and
    // calling the externals allocate nothing; deinit frees that one block (P16.10).
    const gpa = std.testing.allocator;
    var program = try compile.compile_source(gpa,
        \\EXTERNAL e(x)
        \\EXTERNAL f(x)
        \\{e(2)} {f(3)}
        \\
    );
    defer program.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), program.externals.len);
    var counting = CountingAllocator.init(gpa);
    var story: Story = undefined;
    try story.init(counting.allocator(), &program, .{});
    // Freed by hand below to count its frees; until then, a failure frees it here.
    var live = true;
    errdefer if (live) story.deinit(counting.allocator());
    const limits: @import("../core/limits.zig").Limits = .{};
    const shape = state_module.State.shape_of(&program);
    try std.testing.expectEqual(@as(u32, 2), shape.externals_count);
    try std.testing.expectEqual(@as(u64, 1), counting.allocations_count);
    try std.testing.expectEqual(limits.bytes_total(shape), counting.bytes_live);
    story.on_error = support.ignore_message;
    try story.bind_external_function("e", twice, null, true);
    try story.bind_external_function("f", twice, null, true);
    try story.unbind_external_function("f");
    try story.bind_external_function("f", twice, null, true);
    const text = try story.cont();
    try std.testing.expectEqualStrings("4 6\n", text);
    try std.testing.expectEqual(@as(u64, 1), counting.allocations_count);
    story.deinit(counting.allocator());
    live = false;
    try std.testing.expectEqual(@as(u64, 0), counting.bytes_live);
    try std.testing.expectEqual(@as(u64, 1), counting.frees_count);
}
