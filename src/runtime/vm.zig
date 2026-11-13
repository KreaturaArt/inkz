//! The VM (plan §4.8): ink's Story.Step, NextContent and PerformLogicAndFlowControl over the
//! flat program and state. One `step` runs one instruction; `run` steps until something the
//! Continue loop (story.zig) must look at happens, or the budget runs out.
//!
//! A pointer is `{container, index}`; the instruction at it is content item `index` of the
//! container. A nested container is an `enter_container` instruction at its position, so
//! stepping into it is ink's "step directly to the first element of content in a container".
//!
//! Story errors (ink's StoryException) add a diagnostic and return `error.StoryError`; the
//! Continue loop stops there, as ink's catch in ContinueInternal does. Other errors are limits
//! and are returned to the host.

const std = @import("std");
const assert = std.debug.assert;
const index = @import("../core/index.zig");
const instruction_module = @import("../core/instruction.zig");
const extra = @import("../core/extra.zig");
const container_module = @import("../core/container.zig");
const Program = @import("../core/program.zig").Program;
const value_module = @import("value.zig");
const call_stack_module = @import("call_stack.zig");
const lookahead = @import("lookahead.zig");
const state_module = @import("state.zig");
const story_module = @import("story.zig");
const ops = @import("ops.zig");
const Story = story_module.Story;
const Opcode = instruction_module.Opcode;
const Instruction = instruction_module.Instruction;
const Value = value_module.Value;
const Pointer = call_stack_module.Pointer;
const ContainerIndex = index.ContainerIndex;

pub const Error = story_module.Error;

pub fn current_pointer(story: *Story) Pointer {
    assert(story.state.call_stack.frames.count > 0);
    const frame = story.state.call_stack.current_frame();
    const containers_count = story.program.containers.len;
    assert(frame.pointer.is_null() or frame.pointer.container.to_int() < containers_count);
    return frame.pointer;
}

fn set_current_pointer(story: *Story, pointer: Pointer) void {
    assert(story.state.call_stack.frames.count > 0);
    assert(pointer.is_null() or pointer.container.to_int() < story.program.containers.len);
    story.state.call_stack.current_frame().pointer = pointer;
}

fn in_expression(story: *Story) bool {
    assert(story.state.call_stack.frames.count > 0);
    const frame = story.state.call_stack.current_frame();
    assert(frame.kind != .tunnel or frame.temps_count <= story.state.limits.temps_per_frame_max);
    return frame.in_expression_evaluation;
}

fn set_in_expression(story: *Story, value: bool) void {
    assert(story.state.call_stack.frames.count > 0);
    const frame = story.state.call_stack.current_frame();
    frame.in_expression_evaluation = value;
    assert(in_expression(story) == value);
}

/// The instruction a pointer is at, or null past the end or in an empty container.
fn resolve(story: *Story, pointer: Pointer) ?Instruction {
    assert(pointer.container.to_int() < story.program.containers.len);
    assert(!pointer.is_null());
    const count = story.program.content_count(pointer.container);
    if (pointer.index >= count) return null;
    return story.program.instruction_at(pointer.container, pointer.index);
}

/// What a step did with its instruction, for the Continue loop.
pub const Signal = enum { none, output, choice, ended };

/// Why `run` returned.
pub const RunResult = enum {
    /// The output stream changed, or a choice was generated: the Continue loop looks at it.
    output,
    /// The flow ended or the pointer ran out (`can_continue` may now be false).
    ended,
    budget_exhausted,
};

/// Steps until something the Continue loop must look at happens, at most `budget` steps.
/// `steps` counts the steps taken. Between those points, ink's per-step checks in
/// ContinueSingleStep can't change anything: they depend on the output, the choices and
/// whether the story can continue.
pub fn run(story: *Story, budget: u32, steps: *u32) Error!RunResult {
    assert(budget > 0);
    var taken: u32 = 0;
    defer steps.* += taken;
    while (taken < budget) {
        const output_count = story.state.output.items.count;
        const signal = try step(story);
        taken += 1;
        switch (signal) {
            .ended => return .ended,
            .output, .choice => if (loop_must_look(story)) return .output,
            .none => {},
        }
        if (story.state.output.items.count != output_count and loop_must_look(story)) {
            return .output;
        }
        if (current_pointer(story).is_null()) return .ended;
    }
    assert(taken == budget);
    return .budget_exhausted;
}

/// Whether ink's per-step checks (Story.after_steps) can act after an output or a choice
/// (P12.3). They follow a default choice when the story can't continue, and otherwise,
/// outside string evaluation, compare the line with the newline lookahead's or snapshot it
/// when the output ends in a newline. Anywhere else, stepping on is the same as ink's
/// check-after-every-step.
fn loop_must_look(story: *Story) bool {
    assert(story.state.call_stack.frames.count > 0);
    const state = &story.state;
    assert(state.output.items.count <= state.output.items.buffer.len);
    if (!story.can_continue()) return true;
    if (state.output.in_string_evaluation()) return false;
    return lookahead.active(state) or state.output.ends_in_newline();
}

/// ink's Step.
pub fn step(story: *Story) Error!Signal {
    assert(story.state.call_stack.frames.count > 0);
    var pointer = current_pointer(story);
    if (pointer.is_null()) return .ended;
    pointer = try enter_containers(story, pointer);
    set_current_pointer(story, pointer);
    const instruction = resolve(story, pointer) orelse {
        try next_content(story);
        return .none;
    };
    const signal = try perform(story, instruction, pointer);
    if (current_pointer(story).is_null()) return .ended;
    try next_content(story);
    if (instruction.opcode == .start_thread) {
        story.state.call_stack.push_thread() catch |err| return limit(err);
    }
    assert(signal != .ended);
    return signal;
}

/// Steps into nested containers at the pointer, counting each one entered at its start.
fn enter_containers(story: *Story, start: Pointer) Error!Pointer {
    var pointer = start;
    var depth: u32 = 0;
    while (resolve(story, pointer)) |instruction| : (depth += 1) {
        assert(depth <= story.program.containers.len);
        if (instruction.opcode != .enter_container) break;
        const child = instruction.get(.enter_container);
        try visit_container(story, child, true);
        // No content? The most we can do is step past it.
        if (story.program.content_count(child) == 0) break;
        pointer = .start_of(child);
    }
    assert(!pointer.is_null());
    return pointer;
}

/// ink's VisitContainer.
pub fn visit_container(story: *Story, container: ContainerIndex, at_start: bool) Error!void {
    assert(container.to_int() < story.program.containers.len);
    const program = story.program;
    const flags = program.container_field(container, .flags);
    if (flags.count_start_only and !at_start) return;
    const slot = program.container_field(container, .count_slot);
    if (slot == container_module.no_count_slot) return;
    assert(slot < story.state.visit_counts.len);
    const state = &story.state;
    if (flags.visits_counted) {
        const count = state.visit_counts[slot] +% 1;
        try lookahead.set_visit_count(state, slot, count);
    }
    if (flags.turns_counted) {
        try lookahead.set_turn_index(state, slot, state.turn_index);
    }
}

pub fn visit_count(story: *Story, container: ContainerIndex) u32 {
    assert(container.to_int() < story.program.containers.len);
    const slot = story.program.container_field(container, .count_slot);
    if (slot == container_module.no_count_slot) return 0;
    assert(slot < story.state.visit_counts.len);
    return story.state.visit_counts[slot];
}

/// ink's VisitChangedContainersDueToDivert, after a divert, a choice or choose_path_string.
pub fn visit_changed_containers_due_to_divert(story: *Story) Error!void {
    assert(story.diverted_pointer.is_null());
    const pointer = current_pointer(story);
    if (pointer.is_null()) return;
    const previous = story.state.call_stack.current_thread().previous_pointer;
    const ancestors = previous_ancestors(story, previous);
    if (resolve(story, pointer) == null) return;
    // The child is content item `pointer.index` of `pointer.container`.
    var child_index: u32 = pointer.index;
    var ancestor = pointer.container;
    var all_entered_at_start = true;
    var walked: u32 = 0;
    while (!ancestor.is_none()) : (walked += 1) {
        assert(walked <= story.program.containers.len);
        const info = story.program.table().get(ancestor);
        const in_previous = std.mem.indexOfScalar(ContainerIndex, ancestors, ancestor) != null;
        if (in_previous and !info.flags.count_start_only) break;
        const at_start = info.instruction_count > 0 and child_index == 0 and all_entered_at_start;
        if (!at_start) all_entered_at_start = false;
        try visit_container(story, ancestor, at_start);
        child_index = info.index_in_parent;
        ancestor = info.parent;
    }
}

/// The containers the previous pointer was in, innermost first, in the state's scratch.
fn previous_ancestors(story: *Story, previous: Pointer) []const ContainerIndex {
    const scratch = story.state.ancestors;
    assert(scratch.len > 0);
    if (previous.is_null()) return scratch[0..0];
    var ancestor = previous.container;
    if (resolve(story, previous)) |instruction| {
        if (instruction.opcode == .enter_container) ancestor = instruction.get(.enter_container);
    }
    var count: u32 = 0;
    while (!ancestor.is_none() and count < scratch.len) : (count += 1) {
        scratch[count] = ancestor;
        ancestor = story.program.parent(ancestor);
    }
    assert(count <= scratch.len);
    return scratch[0..count];
}

/// ink's NextContent, with its tail call made a loop.
pub fn next_content(story: *Story) Error!void {
    assert(story.state.call_stack.frames.count > 0);
    var rounds: u32 = 0;
    while (true) : (rounds += 1) {
        assert(rounds <= story.state.limits.frames_max + story.state.limits.threads_max);
        const thread = story.state.call_stack.current_thread();
        thread.previous_pointer = current_pointer(story);
        if (!story.diverted_pointer.is_null()) {
            set_current_pointer(story, story.diverted_pointer);
            story.diverted_pointer = .null;
            try visit_changed_containers_due_to_divert(story);
            if (!current_pointer(story).is_null()) return;
        }
        if (increment_pointer(story)) return;
        if (!try pop_after_end(story)) return;
        if (current_pointer(story).is_null()) return;
    }
}

/// Past the end of a function or thread: pops it. Returns whether something was popped.
fn pop_after_end(story: *Story) Error!bool {
    assert(current_pointer(story).is_null());
    assert(story.state.call_stack.depth() > 0);
    const state = &story.state;
    if (state.call_stack.can_pop(.function)) {
        try ops.pop_call_stack(story, .function);
        if (in_expression(story)) try push_evaluation(story, .null);
        return true;
    }
    if (state.call_stack.can_pop_thread()) {
        state.call_stack.pop_thread() catch unreachable;
        return true;
    }
    _ = ops.try_exit_function_evaluation_from_game(story);
    return false;
}

/// ink's IncrementContentPointer: the next item, climbing out of finished containers.
fn increment_pointer(story: *Story) bool {
    var pointer = current_pointer(story);
    assert(!pointer.is_null());
    pointer.index += 1;
    var climbed: u32 = 0;
    while (pointer.index >= story.program.content_count(pointer.container)) : (climbed += 1) {
        assert(climbed <= story.program.containers.len);
        const parent = story.program.container_field(pointer.container, .parent);
        const position = story.program.container_field(pointer.container, .index_in_parent);
        // Named-only containers (knots, stitches) aren't in their parent's content.
        if (parent.is_none() or position == container_module.named_only) {
            set_current_pointer(story, .null);
            return false;
        }
        pointer = .{ .container = parent, .index = position + 1 };
    }
    set_current_pointer(story, pointer);
    return true;
}

/// A call stack failure that isn't a story error: a limit.
fn limit(err: call_stack_module.Error) Error {
    assert(err != error.MismatchedPop);
    assert(err != error.CannotPopThread);
    return switch (err) {
        error.FrameLimit => error.FrameLimit,
        error.ThreadLimit => error.ThreadLimit,
        error.TempLimit => error.TempLimit,
        error.MismatchedPop, error.CannotPopThread => unreachable,
    };
}

pub fn push_evaluation(story: *Story, value: Value) Error!void {
    assert(@sizeOf(Value) == 12);
    story.state.evaluation.push(value) catch return error.EvaluationLimit;
    assert(story.state.evaluation.count > 0);
}

pub fn pop_evaluation(story: *Story) Error!Value {
    assert(@sizeOf(Value) == 12);
    assert(story.state.evaluation.count <= story.state.evaluation.buffer.len);
    const value = story.state.evaluation.pop() orelse return ops.fail(
        story,
        .evaluation_stack_empty,
    );
    return value;
}

/// ink's PerformLogicAndFlowControl, plus pushing plain content where it goes.
fn perform(story: *Story, instruction: Instruction, pointer: Pointer) Error!Signal {
    assert(!pointer.is_null());
    assert(pointer.index < story.program.content_count(pointer.container));
    const opcode = instruction.opcode;
    if (@backingInt(opcode) >= @backingInt(Opcode.add) and
        @backingInt(opcode) <= @backingInt(Opcode.list_invert))
    {
        try ops.call_native(story, opcode);
        return .none;
    }
    return switch (opcode) {
        .text, .newline, .glue, .tag => content_text(story, instruction),
        .integer => push_content(story, .{ .integer = instruction.get(.integer) }),
        .float => push_content(story, .{ .float = instruction.get(.float) }),
        .bool => push_content(story, .{ .bool = instruction.get(.bool) }),
        .void => push_content(story, .null),
        .divert_target => push_content(story, .{
            .divert_target = instruction.get(.divert_target),
        }),
        .variable_pointer => variable_pointer(story, instruction),
        .list => push_content(story, .{ .list = try ops.list_literal(story, instruction) }),
        .enter_container => .none,
        .divert => divert(story, instruction),
        .call_external => ops.call_external(story, instruction),
        .choice_point => choice_point(story, instruction, pointer),
        .global_get, .temp_get, .read_count => variable_get(story, instruction),
        .global_declare, .global_assign, .temp_declare, .temp_assign => assign(story, instruction),
        else => control(story, opcode),
    };
}

fn push_content(story: *Story, value: Value) Error!Signal {
    assert(value != .tag or in_expression(story));
    assert(@sizeOf(Value) == 12);
    if (in_expression(story)) {
        try push_evaluation(story, value);
        return .none;
    }
    // Non-text values in the output stream never show in ink's text; ints from `ev`
    // blocks go through `out`.
    return .none;
}

fn content_text(story: *Story, instruction: Instruction) Error!Signal {
    assert(instruction.opcode == .text or instruction.opcode == .newline or
        instruction.opcode == .glue or instruction.opcode == .tag);
    assert(story.state.call_stack.depth() > 0);
    const opcode = instruction.opcode;
    if (in_expression(story)) {
        return switch (opcode) {
            .text => push_content(story, .{ .string = .program(instruction.get(.text)) }),
            .tag => push_content(story, .{ .tag = .program(instruction.get(.tag)) }),
            .newline => push_content(story, .{ .string = story.program_newline() }),
            else => ops.fail(story, .glue_in_expression),
        };
    }
    switch (opcode) {
        .text => {
            const id = instruction.get(.text);
            const length: u32 = @intCast(story.program.strings.get(id).len);
            try ops.push_text(story, .program(id), 0, length);
        },
        .newline => try ops.push_text(story, story.program_newline(), 0, 1),
        .glue => story.state.output.push_glue() catch return error.OutputLimit,
        .tag => {
            const id = instruction.get(.tag);
            const length: u32 = @intCast(story.program.strings.get(id).len);
            story.state.output.push_tag(.program(id), 0, length) catch return error.OutputLimit;
        },
        else => unreachable,
    }
    return .output;
}

fn variable_pointer(story: *Story, instruction: Instruction) Error!Signal {
    assert(instruction.opcode == .variable_pointer);
    const at = @backingInt(instruction.get(.variable_pointer));
    const record = extra.get(instruction_module.VariablePointer, story.program.extra, at).data;
    var context = record.context;
    if (context == -1) context = story.state.call_stack.context_for(record.name);
    assert(context >= 0);
    return push_content(
        story,
        .{ .variable_pointer = .{ .name = record.name, .context = context } },
    );
}

fn divert(story: *Story, instruction: Instruction) Error!Signal {
    assert(instruction.opcode == .divert);
    const at = @backingInt(instruction.get(.divert));
    const record = extra.get(instruction_module.Divert, story.program.extra, at).data;
    if (record.flags.conditional) {
        const condition = try pop_evaluation(story);
        if (!try ops.truth_of(story, condition)) return .none;
    }
    if (record.flags.variable) {
        const target = try ops.variable_value(story, record.name, -1) orelse
            return ops.fail_name(story, .divert_variable_not_found, record.name);
        if (target != .divert_target) {
            return ops.fail_name(story, .divert_variable_not_target, record.name);
        }
        story.diverted_pointer = .start_of(target.divert_target);
    } else {
        const target = record.target_container;
        story.diverted_pointer = .{ .container = target, .index = record.target_index };
    }
    switch (record.flags.kind) {
        .plain => {},
        .function => try push_frame(story, .function),
        .tunnel => try push_frame(story, .tunnel),
    }
    assert(!story.diverted_pointer.is_null());
    return .none;
}

fn push_frame(story: *Story, kind: call_stack_module.FrameKind) Error!void {
    const state = &story.state;
    assert(state.call_stack.depth() > 0);
    assert(kind != .function_evaluation_from_game);
    state.call_stack.push(kind, state.evaluation.count, state.output.items.count) catch
        return error.FrameLimit;
}

fn choice_point(story: *Story, instruction: Instruction, pointer: Pointer) Error!Signal {
    assert(instruction.opcode == .choice_point);
    assert(!pointer.is_null());
    const at = @backingInt(instruction.get(.choice_point));
    const record = extra.get(instruction_module.ChoicePoint, story.program.extra, at).data;
    try ops.process_choice(story, record, pointer);
    return .choice;
}

fn variable_get(story: *Story, instruction: Instruction) Error!Signal {
    assert(story.state.evaluation.count <= story.state.evaluation.buffer.len);
    assert(@sizeOf(Value) == 12);
    const value: Value = switch (instruction.opcode) {
        .read_count => .{ .integer = @bitCast(visit_count(story, instruction.get(.read_count))) },
        .global_get => try ops.global_value(story, instruction.get(.global_get)),
        .temp_get => try ops.temp_value(story, instruction.get(.temp_get)),
        else => unreachable,
    };
    try push_evaluation(story, value);
    return .none;
}

fn assign(story: *Story, instruction: Instruction) Error!Signal {
    assert(story.state.evaluation.count <= story.state.evaluation.buffer.len);
    assert(@sizeOf(Value) == 12);
    const value = try pop_evaluation(story);
    switch (instruction.opcode) {
        .global_declare => try ops.declare_global(story, instruction.get(.global_declare), value),
        .global_assign => try ops.assign_global(story, instruction.get(.global_assign), value),
        .temp_declare => try ops.declare_temp(story, instruction.get(.temp_declare), value),
        .temp_assign => try ops.assign_temp(story, instruction.get(.temp_assign), value),
        else => unreachable,
    }
    return .none;
}

/// ink's ControlCommand cases.
fn control(story: *Story, opcode: Opcode) Error!Signal {
    assert(@backingInt(opcode) >= @backingInt(Opcode.eval_start));
    assert(@backingInt(opcode) < @backingInt(Opcode.add));
    const state = &story.state;
    switch (opcode) {
        .eval_start => set_in_expression(story, true),
        .eval_end => set_in_expression(story, false),
        .eval_output => return ops.eval_output(story),
        .nop, .start_thread => {},
        .duplicate => {
            const top = state.evaluation.peek() orelse return ops.fail(
                story,
                .evaluation_stack_empty,
            );
            try push_evaluation(story, top);
        },
        .pop => _ = try pop_evaluation(story),
        .function_return => try ops.pop_function_or_tunnel(story, .function),
        .tunnel_return => try ops.pop_function_or_tunnel(story, .tunnel),
        .string_start => {
            state.output.push_command(.begin_string) catch return error.OutputLimit;
            set_in_expression(story, false);
            return .output;
        },
        .string_end => return ops.end_string(story),
        .tag_start => {
            state.output.push_command(.begin_tag) catch return error.OutputLimit;
            return .output;
        },
        .tag_end => return ops.end_tag(story),
        .choice_count => try push_evaluation(story, .{
            .integer = @intCast(state.choices.count()),
        }),
        .turns => try push_evaluation(story, .{ .integer = state.turn_index +% 1 }),
        .turns_since, .read_count_of_target => try count_of_target(story, opcode),
        .random => try ops.random(story),
        .seed_random => try ops.seed_random(story),
        .visit_index => {
            const count = visit_count(story, current_pointer(story).container);
            try push_evaluation(story, .{ .integer = @as(i32, @bitCast(count)) -% 1 });
        },
        .sequence_shuffle_index => try ops.sequence_shuffle_index(story),
        .done => ops.done(story) catch |err| return err,
        .end => ops.force_end(story),
        .list_from_int, .list_range, .list_random => try ops.list_command(story, opcode),
        else => unreachable,
    }
    return .none;
}

fn count_of_target(story: *Story, opcode: Opcode) Error!void {
    assert(opcode == .turns_since or opcode == .read_count_of_target);
    assert(story.state.evaluation.count <= story.state.evaluation.buffer.len);
    const target = try pop_evaluation(story);
    if (target != .divert_target) return ops.fail(story, .turns_since_expected_target);
    const container = target.divert_target;
    const count: i32 = if (opcode == .turns_since)
        ops.turns_since(story, container)
    else
        @bitCast(visit_count(story, container));
    try push_evaluation(story, .{ .integer = count });
}
