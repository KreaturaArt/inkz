//! A story on the new runtime (plan §4.6, §4.7): a borrowed program, one state, and ink's
//! Continue loop around the VM. The public API (P6) wraps this.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Program = @import("../core/program.zig").Program;
const Limits = @import("../core/limits.zig").Limits;
const state_module = @import("state.zig");
const call_stack_module = @import("call_stack.zig");
const output_module = @import("output.zig");
const choices_module = @import("choices.zig");
const value_module = @import("value.zig");
const lookahead = @import("lookahead.zig");
const vm = @import("vm.zig");
const ops = @import("ops.zig");
const State = state_module.State;
const Pointer = call_stack_module.Pointer;
const StringReference = value_module.StringReference;

pub const Error = error{
    /// A story error was recorded (ink's StoryException); see `State.errors`.
    StoryError,
    EvaluationLimit,
    FrameLimit,
    ThreadLimit,
    TempLimit,
    OutputLimit,
    TextTooLong,
    HeapLimit,
    ListLimit,
    ChoiceLimit,
    TagLimit,
    SnapshotLimit,
    LookaheadLogLimit,
    StepLimit,
};

pub const Story = struct {
    program: *const Program,
    state: State,
    /// ink's divertedPointer: where the next NextContent goes. Only set within a step.
    diverted_pointer: Pointer = .null,
    saw_lookahead_unsafe_function_after_newline: bool = false,
    /// The cleaned text length and tag count when the lookahead snapshot was taken.
    snapshot_text_length: u32 = 0,
    snapshot_tags_count: u32 = 0,
    /// The last line returned by `cont`, in `state.line_bytes`.
    line_length: u32 = 0,

    pub fn init(story: *Story, gpa: Allocator, program: *const Program, limits: Limits) !void {
        assert(program.containers.len > 0);
        story.* = .{ .program = program, .state = undefined };
        try story.state.init(gpa, program, limits);
        errdefer story.state.deinit(gpa);
        try story.reset_globals();
        assert(story.state.call_stack.depth() == 1);
    }

    pub fn deinit(story: *Story, gpa: Allocator) void {
        const shape = State.shape_of(story.program);
        assert(story.state.memory.len == story.state.limits.bytes_total(shape));
        assert(story.state.memory.len > 0);
        story.state.deinit(gpa);
        story.* = undefined;
    }

    pub fn program_newline(story: *const Story) StringReference {
        assert(story.program.strings.get(story.program.newline).len == 1);
        assert(!story.program.newline.is_none());
        return .program(story.program.newline);
    }

    /// ink's ResetGlobals: runs `global decl` from its start, then keeps the defaults.
    fn reset_globals(story: *Story) Error!void {
        assert(story.state.call_stack.depth() == 1);
        const declaration = story.program.global_declaration;
        if (!declaration.is_none()) {
            const original = vm.current_pointer(story);
            try story.choose_pointer(.start_of(declaration), false);
            _ = try story.continue_internal();
            story.state.call_stack.current_frame().pointer = original;
        }
        @memcpy(story.state.global_defaults, story.state.globals);
        assert(story.state.global_defaults.len == story.state.globals.len);
    }

    /// ink's canContinue.
    pub fn can_continue(story: *Story) bool {
        assert(story.state.call_stack.depth() > 0);
        assert(story.state.memory.len > 0);
        return !vm.current_pointer(story).is_null() and !story.state.has_error();
    }

    /// ink's Continue: the next line. Story errors stay in `state.errors`.
    pub fn cont(story: *Story) Error![]const u8 {
        assert(story.state.line_bytes.len > 0);
        assert(story.can_continue());
        story.state.did_safe_exit = false;
        story.state.output.clear();
        const length = try story.continue_internal();
        story.line_length = length;
        return story.state.line_bytes[0..length];
    }

    /// ink's ContinueInternal, from the loop to the end-of-content checks; returns the
    /// line's length in `line_bytes`.
    fn continue_internal(story: *Story) Error!u32 {
        assert(story.state.call_stack.depth() > 0);
        assert(story.state.limits.steps_per_continue_max > 0);
        story.saw_lookahead_unsafe_function_after_newline = false;
        var ends_in_newline = false;
        var steps: u32 = 0;
        const steps_max = story.state.limits.steps_per_continue_max;
        while (true) {
            if (steps == steps_max) return error.StepLimit;
            const result = vm.run(story, steps_max - steps, &steps) catch |err| switch (err) {
                error.StoryError => break,
                else => |other| return other,
            };
            if (result == .budget_exhausted) return error.StepLimit;
            ends_in_newline = story.after_steps() catch |err| switch (err) {
                error.StoryError => break,
                else => |other| return other,
            };
            if (ends_in_newline or !story.can_continue()) break;
        }
        if (ends_in_newline or !story.can_continue()) {
            if (lookahead.active(&story.state)) lookahead.restore(&story.state);
            if (!story.can_continue()) story.check_end_of_content();
            story.state.did_safe_exit = false;
            story.saw_lookahead_unsafe_function_after_newline = false;
        }
        return story.write_current_text();
    }

    /// The checks of ink's ContinueSingleStep after `vm.run` returns; returns whether the
    /// line is known to have ended.
    fn after_steps(story: *Story) Error!bool {
        assert(story.state.memory.len > 0);
        assert(story.state.call_stack.depth() > 0);
        const state = &story.state;
        const from_game = state.call_stack.current_frame().kind == .function_evaluation_from_game;
        if (!story.can_continue() and !from_game) {
            _ = try story.try_follow_default_invisible_choice();
        }
        if (state.output.in_string_evaluation()) return false;
        if (lookahead.active(state)) {
            const change = try story.newline_change();
            if (change == .extended or story.saw_lookahead_unsafe_function_after_newline) {
                lookahead.restore(state);
                return true;
            }
            if (change == .newline_removed) lookahead.discard(state);
        }
        if (state.output.ends_in_newline()) {
            if (story.can_continue()) {
                if (!lookahead.active(state)) try story.take_snapshot();
            } else if (lookahead.active(state)) {
                lookahead.discard(state);
            }
        }
        return false;
    }

    fn take_snapshot(story: *Story) Error!void {
        assert(!lookahead.active(&story.state));
        story.snapshot_text_length = try story.write_current_text();
        story.snapshot_tags_count = try story.current_tags_count();
        lookahead.take(&story.state);
        assert(lookahead.active(&story.state));
    }

    const Change = enum { none, extended, newline_removed };

    /// ink's CalculateNewlineOutputStateChange, against the snapshot's text and tags.
    fn newline_change(story: *Story) Error!Change {
        assert(lookahead.active(&story.state));
        assert(story.snapshot_text_length <= story.state.line_bytes.len);
        const previous = story.snapshot_text_length;
        const length = try story.write_current_text();
        const text = story.state.line_bytes[0..length];
        const tags = try story.current_tags_count();
        const newline_still_exists =
            length >= previous and previous > 0 and text[previous - 1] == '\n';
        if (tags == story.snapshot_tags_count and length == previous and newline_still_exists) {
            return .none;
        }
        if (!newline_still_exists) return .newline_removed;
        if (tags > story.snapshot_tags_count) return .extended;
        for (text[previous..]) |character| {
            if (character != ' ' and character != '\t') return .extended;
        }
        return .none;
    }

    /// The current text, cleaned, into `line_bytes`; returns its length.
    fn write_current_text(story: *Story) Error!u32 {
        assert(story.state.line_bytes.len > 0);
        var writer: std.Io.Writer = .fixed(story.state.line_bytes);
        story.state.output.write_text(ops.strings_of(story), &writer) catch
            return error.OutputLimit;
        assert(writer.end <= story.state.line_bytes.len);
        return @intCast(writer.end);
    }

    fn current_tags_count(story: *Story) Error!u32 {
        assert(story.state.memory.len > 0);
        assert(story.state.output.items.count <= story.state.output.items.buffer.len);
        var counter: TagCounter = .{};
        story.state.output.collect_tags(ops.strings_of(story), &counter) catch
            return error.OutputLimit;
        return counter.count;
    }

    /// Calls `sink.tag(text)` for each tag of the current line.
    pub fn current_tags(story: *Story, sink: anytype) !void {
        assert(@typeInfo(@TypeOf(sink)) == .pointer);
        assert(story.state.memory.len > 0);
        try story.state.output.collect_tags(ops.strings_of(story), sink);
    }

    /// ink's end-of-content errors, when the story can't continue.
    fn check_end_of_content(story: *Story) void {
        assert(!story.can_continue());
        assert(story.state.call_stack.depth() > 0);
        const state = &story.state;
        if (state.call_stack.can_pop_thread()) {
            ops.fail(story, .thread_left_to_pop) catch {};
        }
        if (state.choices.count() != 0 or state.did_safe_exit) return;
        const code: state_module.Diagnostic.Code = if (state.call_stack.can_pop(.tunnel))
            .unexpected_end_of_tunnel
        else if (state.call_stack.can_pop(.function))
            .unexpected_end_of_function
        else if (!state.call_stack.can_pop(null))
            .ran_out_of_content
        else
            .unexpected_end_unknown;
        ops.fail(story, code) catch {};
    }

    /// ink's TryFollowDefaultInvisibleChoice.
    fn try_follow_default_invisible_choice(story: *Story) Error!bool {
        assert(!story.can_continue());
        assert(story.state.choices.count() <= story.state.choices.records.buffer.len);
        const choices = &story.state.choices;
        var invisible: ?choices_module.Choice = null;
        for (choices.records.slice()) |choice| {
            if (!choice.invisible_default) return false;
            if (invisible == null) invisible = choice;
        }
        const choice = invisible orelse return false;
        const stack = &story.state.call_stack;
        choices.restore(stack, choice) catch return error.FrameLimit;
        if (lookahead.active(&story.state)) {
            // ink forks the thread so the snapshot's copy stays intact.
            stack.thread_counter += 1;
            stack.current_thread().counter = stack.thread_counter;
        }
        try story.choose_pointer(choice.target, false);
        return true;
    }

    /// ink's ChoosePath with a resolved target.
    pub fn choose_pointer(
        story: *Story,
        target: Pointer,
        incrementing_turn_index: bool,
    ) Error!void {
        assert(target.container.to_int() < story.program.containers.len);
        assert(!target.is_null());
        story.state.choices.clear();
        story.state.call_stack.current_frame().pointer = target;
        if (incrementing_turn_index) story.state.turn_index +%= 1;
        try vm.visit_changed_containers_due_to_divert(story);
    }

    /// The choices shown to the player (ink's currentChoices): none while the story can
    /// continue, and never the invisible defaults.
    pub fn visible_choices_count(story: *Story) u32 {
        assert(story.state.choices.count() <= story.state.choices.records.buffer.len);
        if (story.can_continue()) return 0;
        var count: u32 = 0;
        for (story.state.choices.records.slice()) |choice| {
            if (!choice.invisible_default) count += 1;
        }
        assert(count <= story.state.choices.count());
        return count;
    }

    pub fn visible_choice(story: *Story, position: u32) choices_module.Choice {
        assert(story.state.choices.count() > 0);
        assert(position < story.visible_choices_count());
        var seen: u32 = 0;
        for (story.state.choices.records.slice()) |choice| {
            if (choice.invisible_default) continue;
            if (seen == position) return choice;
            seen += 1;
        }
        unreachable;
    }

    /// ink's ChooseChoiceIndex.
    pub fn choose_choice_index(story: *Story, position: u32) Error!void {
        assert(!story.can_continue());
        const choice = story.visible_choice(position);
        story.state.choices.restore(&story.state.call_stack, choice) catch return error.FrameLimit;
        try story.choose_pointer(choice.target, true);
        assert(story.state.choices.count() == 0);
    }

    pub fn text_of(story: *const Story, reference: StringReference) []const u8 {
        assert(story.state.memory.len > 0);
        assert(reference != StringReference.none);
        return ops.strings_of(story).get(reference);
    }
};

const TagCounter = struct {
    count: u32 = 0,

    pub fn tag(counter: *TagCounter, text: []const u8) !void {
        assert(counter.count < std.math.maxInt(u32));
        assert(text.len < 1 << 20);
        counter.count += 1;
    }
};

pub const pop_call_stack = ops.pop_call_stack;
pub const try_exit_function_evaluation_from_game = ops.try_exit_function_evaluation_from_game;

comptime {
    _ = output_module;
}

const ProgramBuilder = @import("../core/program_builder.zig").ProgramBuilder;

test "a step budget stops a story that loops without output" {
    // Goal: P5.1; `steps_per_continue_max` is a hard limit. Method: a container that diverts
    // to itself forever; run reports the exhausted budget and cont returns StepLimit.
    const gpa = std.testing.allocator;
    var builder = try ProgramBuilder.init(gpa);
    defer builder.deinit();
    _ = try builder.begin_container(.{});
    try builder.add(.text, try builder.intern("start"));
    try builder.add(.newline, {});
    _ = try builder.begin_container(.{ .name = "spin" });
    try builder.add(.nop, {});
    try builder.add_divert("spin", .{ .kind = .plain, .conditional = false, .variable = false });
    try builder.end_container();
    try builder.end_container();
    var program = try builder.finish();
    defer program.deinit(gpa);
    var story: Story = undefined;
    try story.init(gpa, &program, .{ .steps_per_continue_max = 100 });
    defer story.deinit(gpa);
    var steps: u32 = 0;
    try std.testing.expectEqual(vm.RunResult.output, try vm.run(&story, 100, &steps));
    try std.testing.expectError(error.StepLimit, story.cont());
    var more: u32 = 0;
    try std.testing.expectEqual(vm.RunResult.budget_exhausted, try vm.run(&story, 50, &more));
    try std.testing.expectEqual(@as(u32, 50), more);
}
