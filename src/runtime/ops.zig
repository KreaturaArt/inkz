//! The semantics behind the VM's instructions, each ported from ink's Story.cs,
//! StoryState.cs and VariablesState.cs: variables, native calls, strings and tags, choices,
//! randomness and the ends of flow. `vm.zig` dispatches; these do the work.
//!
//! Heap safety: an allocation may compact the heap, which moves strings and lists. Values a
//! function still needs are either on a root (the evaluation stack) or passed as `keep`, and
//! byte slices are only taken after the last allocation.

const std = @import("std");
const builtin = @import("builtin");
const profile = @import("../core/profile.zig");
const assert = std.debug.assert;
const index = @import("../core/index.zig");
const instruction_module = @import("../core/instruction.zig");
const extra = @import("../core/extra.zig");
const container_module = @import("../core/container.zig");
const Program = @import("../core/program.zig").Program;
const DotnetRandom = @import("../core/dotnet_random.zig").DotnetRandom;
const value_module = @import("value.zig");
const native = @import("native.zig");
const lists_module = @import("lists.zig");
const heap = @import("heap.zig");
const call_stack_module = @import("call_stack.zig");
const output_module = @import("output.zig");
const choices_module = @import("choices.zig");
const lookahead = @import("lookahead.zig");
const state_module = @import("state.zig");
const story_module = @import("story.zig");
const vm = @import("vm.zig");
const Story = story_module.Story;
const Error = story_module.Error;
const Opcode = instruction_module.Opcode;
const Instruction = instruction_module.Instruction;
const Value = value_module.Value;
const StringReference = value_module.StringReference;
const ListReference = value_module.ListReference;
const Pointer = call_stack_module.Pointer;
const ContainerIndex = index.ContainerIndex;
const StringId = index.StringId;
const GlobalSlot = index.GlobalSlot;
const ListItemIndex = index.ListItemIndex;
const ListOriginIndex = index.ListOriginIndex;
const Code = state_module.Diagnostic.Code;

/// Strings by reference: the program's pool or the state's heap.
pub const Strings = struct {
    program: *const Program,
    heap: *const heap.StringHeap,

    pub fn get(strings: Strings, reference: StringReference) []const u8 {
        assert(reference != StringReference.none);
        if (reference.is_heap()) return strings.heap.get(reference);
        const id = reference.program_id();
        assert(id.to_int() < strings.program.strings.count());
        return strings.program.strings.get(id);
    }
};

pub fn strings_of(story: *const Story) Strings {
    assert(story.program.strings.count() > 0);
    assert(story.state.strings.used <= story.state.strings.bytes.len);
    return .{ .program = story.program, .heap = &story.state.strings };
}

fn lists_of(story: *Story) lists_module.Lists {
    assert(story.program.list_items.len < 1 << 20);
    return .{ .program = story.program, .slab = &story.state.lists };
}

/// What an error message prints besides its code: a name, a second string, or two numbers.
pub const Arguments = struct {
    name: StringId = .none,
    detail: StringReference = .none,
    numbers: [2]i32 = .{ 0, 0 },
};

/// ink's AddError for an error, which throws: records it where the story is, ends the flow
/// (ink's ForceEnd: "in a broken state don't need to know about any other errors") and
/// returns `error.StoryError`.
pub fn fail(story: *Story, code: Code, arguments: Arguments) Error {
    assert(@backingInt(code) > 0 or code == .story_error);
    story.state.add_diagnostic(.{
        .argument = if (arguments.name.is_none()) .none else .program(arguments.name),
        .detail = arguments.detail,
        .number = arguments.numbers[0],
        .other_number = arguments.numbers[1],
        .pointer = vm.current_pointer(story),
        .code = code,
        .severity = .@"error",
    });
    force_end(story);
    assert(story.state.has_error());
    return error.StoryError;
}

pub fn warn_name(story: *Story, code: Code, name: StringId) void {
    assert(!name.is_none());
    const argument: StringReference = .program(name);
    story.state.add_diagnostic(.{
        .argument = argument,
        .pointer = vm.current_pointer(story),
        .code = code,
        .severity = .warning,
    });
    assert(story.state.has_warning());
}

/// ink's isTruthy; a divert target or other value without a truth value is a story error.
pub fn truth_of(story: *Story, value: Value) Error!bool {
    var context: NativeContext = .{ .story = story };
    return value.is_truthy(&context) catch fail(story, .no_truth_value, .{});
}

// Output.

pub fn push_text(story: *Story, string: StringReference, start: u32, length: u32) Error!void {
    const state = &story.state;
    assert(length < 1 << 31);
    const frames = state.call_stack.current_frames();
    try state.output.push_text(strings_of(story), frames, string, start, length);
    assert(state.output.items.count <= state.output.items.buffer.len);
}

/// ink's PopCallstack: a function's trailing whitespace goes when it returns.
pub fn pop_call_stack(story: *Story, kind: ?call_stack_module.FrameKind) Error!void {
    assert(story.state.call_stack.depth() > 1);
    const state = &story.state;
    const frame = state.call_stack.current_frame();
    if (frame.kind == .function) state.output.trim_function_end(frame.function_start_in_output);
    state.call_stack.pop(kind) catch return fail(story, .pop_mismatch, .{});
    assert(state.call_stack.depth() > 0);
}

pub fn try_exit_function_evaluation_from_game(story: *Story) bool {
    assert(story.state.call_stack.depth() > 0);
    const frame = story.state.call_stack.current_frame();
    if (frame.kind != .function_evaluation_from_game) return false;
    frame.pointer = .null;
    story.state.did_safe_exit = true;
    assert(frame.pointer.is_null());
    return true;
}

/// `~ret` and `->->`, with ink's optional divert target after `->->`.
pub fn pop_function_or_tunnel(story: *Story, kind: call_stack_module.FrameKind) Error!void {
    assert(kind != .function_evaluation_from_game);
    var override: ?ContainerIndex = null;
    if (kind == .tunnel) {
        const popped = try vm.pop_evaluation(story);
        switch (popped) {
            .divert_target => |target| override = target,
            .null => {},
            else => return fail(story, .tunnel_return_not_target, .{}),
        }
    }
    if (try_exit_function_evaluation_from_game(story)) return;
    const stack = &story.state.call_stack;
    if (stack.current_frame().kind != kind or !stack.can_pop(null)) {
        // ink's names: what was found, and what the current frame (or the flow's end) wanted.
        const frame_kind = stack.current_frame().kind;
        const current: i32 = if (stack.can_pop(null)) @backingInt(frame_kind) else 2;
        return fail(story, .pop_unexpected, .{ .numbers = .{ @backingInt(kind), current } });
    }
    try pop_call_stack(story, null);
    if (override) |target| story.diverted_pointer = .start_of(target);
    assert(stack.depth() > 0);
}

/// `out`: the top value as text, if the expression left one.
pub fn eval_output(story: *Story) Error!vm.Signal {
    const state = &story.state;
    const value = state.evaluation.pop() orelse return .none;
    switch (value) {
        .null => return .none,
        .string => |reference| {
            const length: u32 = @intCast(strings_of(story).get(reference).len);
            try push_text(story, reference, 0, length);
        },
        else => {
            const text = try value_text(story, value);
            const reference = try store_string(story, text, &.{});
            try push_text(story, reference, 0, @intCast(text.len));
        },
    }
    assert(state.output.items.count <= state.output.items.buffer.len);
    return .output;
}

/// A value's ink ToString as a string: the string itself, or its text in a new heap string.
pub fn value_string(story: *Story, value: Value) Error!StringReference {
    if (value == .string) return value.string;
    const text = try value_text(story, value);
    return store_string(story, text, &.{});
}

/// A value's ink ToString, in the line buffer (free while stepping).
fn value_text(story: *Story, value: Value) Error![]const u8 {
    assert(story.state.line_bytes.len > 0);
    var writer: std.Io.Writer = .fixed(story.state.line_bytes);
    switch (value) {
        .integer => |number| writer.print("{d}", .{number}) catch return error.OutputLimit,
        .float => |number| {
            var buffer: [value_module.float_text_bytes_max]u8 = undefined;
            writer.writeAll(value_module.format_float(number, &buffer)) catch
                return error.OutputLimit;
        },
        .bool => |flag| writer.writeAll(if (flag) "true" else "false") catch
            return error.OutputLimit,
        .list => |list| lists_of(story).write(list, &writer) catch |err| switch (err) {
            error.ListLimit => return error.ListLimit,
            error.WriteFailed => return error.OutputLimit,
        },
        .divert_target => |target| {
            const path = story.program.container_info(target).path;
            writer.print("DivertTargetValue({s})", .{story.program.strings.get(path)}) catch
                return error.OutputLimit;
        },
        .variable_pointer => |pointer| {
            const name = story.program.strings.get(pointer.name);
            writer.print("VariablePointerValue({s})", .{name}) catch return error.OutputLimit;
        },
        .string, .tag => |reference| writer.writeAll(strings_of(story).get(reference)) catch
            return error.OutputLimit,
        .null => {},
    }
    assert(writer.end <= story.state.line_bytes.len);
    note_line_bytes(&story.state, writer.end);
    return writer.buffered();
}

/// Records how much of the line buffer scratch was used.
fn note_line_bytes(state: *state_module.State, used: usize) void {
    assert(used <= state.line_bytes.len);
    assert(state.line_bytes.len > 0);
    state.peaks.line_bytes = @max(state.peaks.line_bytes, @as(u32, @intCast(used)));
}

/// Whether `text` lies in the string heap, where an allocation may move it.
fn in_heap(story: *const Story, text: []const u8) bool {
    const heap_bytes = story.state.strings.bytes;
    assert(heap_bytes.len > 0);
    const start = @intFromPtr(heap_bytes.ptr);
    return @intFromPtr(text.ptr) >= start and @intFromPtr(text.ptr) < start + heap_bytes.len;
}

/// Copies `text` into a new heap string. Text inside the heap is copied out first, since
/// the allocation may compact.
pub fn store_string(story: *Story, text_raw: []const u8, keep: []Value) Error!StringReference {
    assert(text_raw.len < 1 << 31);
    var text = text_raw;
    if (in_heap(story, text)) {
        if (text.len > story.state.line_bytes.len) return error.OutputLimit;
        @memcpy(story.state.line_bytes[0..text.len], text);
        text = story.state.line_bytes[0..text.len];
        note_line_bytes(&story.state, text.len);
    }
    const reference = story.state.allocate_string(@intCast(text.len), keep) catch
        return error.HeapLimit;
    @memcpy(story.state.strings.get(reference), text);
    assert(reference.is_heap());
    return reference;
}

/// `/str`: the text since `str` becomes a string value.
pub fn end_string(story: *Story) Error!vm.Signal {
    assert(story.state.output.in_string_evaluation());
    assert(story.state.line_bytes.len > 0);
    const state = &story.state;
    var writer: std.Io.Writer = .fixed(state.line_bytes);
    _ = state.output.end_string(strings_of(story), &writer) catch |err| switch (err) {
        error.UnmatchedEndString => return fail(story, .unmatched_end_string, .{}),
        else => return error.OutputLimit,
    };
    note_line_bytes(state, writer.end);
    const reference = try store_string(story, writer.buffered(), &.{});
    state.call_stack.current_frame().in_expression_evaluation = true;
    try vm.push_evaluation(story, .{ .string = reference });
    return .output;
}

/// `/#`: inside string evaluation the tag becomes a value for the next choice; otherwise
/// the marker goes to the output.
pub fn end_tag(story: *Story) Error!vm.Signal {
    assert(story.state.line_bytes.len > 0);
    assert(story.state.output.items.count <= story.state.output.items.buffer.len);
    const state = &story.state;
    if (!state.output.in_string_evaluation()) {
        state.output.push_command(.end_tag) catch return error.OutputLimit;
        return .output;
    }
    const items = state.output.items.slice();
    // As ink's Story.cs: only a control command other than `#` is an error; glue and tag
    // values inside the tag are dropped with it, and only its text is kept.
    var start = items.len;
    while (start > 0) {
        start -= 1;
        switch (items[start].kind) {
            .begin_tag => break,
            .begin_string, .end_tag => return fail(story, .unexpected_command_in_tag, .{}),
            .text, .glue, .tag => {},
        }
    } else return fail(story, .unexpected_command_in_tag, .{});
    assert(items[start].kind == .begin_tag);
    var writer: std.Io.Writer = .fixed(state.line_bytes);
    var cleaner: output_module.Cleaner = .{ .writer = &writer };
    for (items[start + 1 ..]) |item| {
        if (item.kind != .text) continue;
        const whole = strings_of(story).get(item.string);
        cleaner.write(whole[item.start..][0..item.length]) catch return error.OutputLimit;
    }
    state.output.items.truncate(@intCast(start));
    note_line_bytes(state, writer.end);
    const reference = try store_string(story, writer.buffered(), &.{});
    try vm.push_evaluation(story, .{ .tag = reference });
    return .output;
}

// Native functions.

fn is_unary(opcode: Opcode) bool {
    assert(@backingInt(opcode) <= @backingInt(Opcode.list_invert));
    const result = switch (opcode) {
        .negate, .not, .floor, .ceiling, .int, .float_cast => true,
        .list_min, .list_max, .list_all, .list_count, .list_value, .list_invert => true,
        else => false,
    };
    assert(@backingInt(opcode) >= @backingInt(Opcode.add));
    return result;
}

pub fn call_native(story: *Story, opcode: Opcode) Error!void {
    const profile_zone = profile.begin(.call_native);
    defer profile_zone.end();
    assert(@backingInt(opcode) >= @backingInt(Opcode.add));
    assert(@backingInt(opcode) <= @backingInt(Opcode.list_invert));
    var operands: [2]Value = undefined;
    const count: u32 = if (is_unary(opcode)) 1 else 2;
    var position = count;
    while (position > 0) {
        position -= 1;
        operands[position] = try vm.pop_evaluation(story);
    }
    try reserve(story, operands[0..count]);
    var context: NativeContext = .{ .story = story };
    // A runtime switch on the opcode: comptime prongs (fino's) measured no faster (F15,
    // docs/benchmarks.md).
    const result = if (count == 1)
        native.unary(&context, opcode, operands[0])
    else
        native.binary(&context, opcode, operands[0], operands[1]);
    const value = result catch |err| return native_failure(story, err, opcode, operands[0..count]);
    try vm.push_evaluation(story, value);
}

fn native_failure(story: *Story, err: native.Error, opcode: Opcode, operands: []const Value) Error {
    assert(err != error.ListLimit or story.program.list_items.len > 0);
    assert(operands.len > 0);
    return switch (err) {
        error.ListOperandTypes => list_operand_types(story, opcode, operands),
        error.HeapLimit => error.HeapLimit,
        error.ListLimit => error.ListLimit,
        error.DivisionByZero => fail(story, .division_by_zero, .{}),
        error.IntegerOverflow => fail(story, .integer_overflow, .{}),
        error.FloatToIntegerOutOfRange => fail(story, .float_to_integer_out_of_range, .{}),
        error.VoidOperand => fail(story, .void_operand, .{}),
        error.UnsupportedOperation => operation_not_for_type(story, opcode, operands),
        error.IncompatibleTypes => fail(story, .unsupported_operation, .{}),
    };
}

/// ink's "Cannot perform operation '<op>' on <type>": the type is the one ink's
/// CoerceValuesToSingleType gives the operands (at least Int, so a Bool is an Int).
fn operation_not_for_type(story: *Story, opcode: Opcode, operands: []const Value) Error {
    assert(operands.len == 1 or operands.len == 2);
    var rank: i8 = 0;
    for (operands) |operand| rank = @max(rank, operand.rank() orelse 0);
    assert(rank >= 0 and rank <= 5);
    return fail(story, .operation_not_for_type, .{ .numbers = .{ @backingInt(opcode), rank } });
}

/// ink's "Can not call use '<op>' operation on <type> and <type>": the opcode and both
/// operands' types go into the diagnostic's numbers for the message.
fn list_operand_types(story: *Story, opcode: Opcode, operands: []const Value) Error {
    assert(operands.len == 2);
    assert(operands[0] == .list or operands[1] == .list);
    const left: i32 = @backingInt(std.meta.activeTag(operands[0]));
    const right: i32 = @backingInt(std.meta.activeTag(operands[1]));
    const numbers: [2]i32 = .{ @backingInt(opcode), left << 8 | right };
    return fail(story, .list_operand_types, .{ .numbers = numbers });
}

/// Makes room for the result of an operation on `operands` so that it can't compact: a
/// string concatenation or one list, at most.
fn reserve(story: *Story, operands: []Value) Error!void {
    assert(operands.len <= 2);
    assert(story.state.strings.used <= story.state.strings.bytes.len);
    const state = &story.state;
    var string_bytes: u32 = 8 + 3;
    var has_list = false;
    for (operands) |operand| {
        string_bytes += switch (operand) {
            .string => |reference| @intCast(strings_of(story).get(reference).len),
            else => value_module.float_text_bytes_max + 8,
        };
        if (operand == .list) has_list = true;
    }
    const short = state.strings.bytes.len - state.strings.used < string_bytes;
    if (short or state.compact_always) state.compact(operands);
    state.strings.note_need(string_bytes);
    if (state.strings.bytes.len - state.strings.used < string_bytes) return error.HeapLimit;
    if (has_list) try reserve_list(story, operands);
}

const NativeContext = struct {
    story: *Story,

    pub fn string_bytes(context: *NativeContext, reference: StringReference) []const u8 {
        assert(reference != StringReference.none);
        return strings_of(context.story).get(reference);
    }

    /// Room was reserved first, so this never compacts and `a` and `b` stay valid.
    pub fn string_concat(
        context: *NativeContext,
        a: []const u8,
        b: []const u8,
    ) native.Error!StringReference {
        assert(a.len + b.len < 1 << 31);
        const strings = &context.story.state.strings;
        const length: u32 = @intCast(a.len + b.len);
        const reference = strings.try_allocate(length) orelse return error.HeapLimit;
        const target = strings.get(reference);
        @memcpy(target[0..a.len], a);
        @memcpy(target[a.len..], b);
        assert(target.len == a.len + b.len);
        return reference;
    }

    pub fn list_count(context: *NativeContext, list: ListReference) u32 {
        assert(context.story.state.lists.check_reference(list));
        return lists_of(context.story).count(list);
    }

    pub fn list_binary(
        context: *NativeContext,
        opcode: Opcode,
        a: Value,
        b: Value,
    ) native.Error!Value {
        assert(@backingInt(opcode) >= @backingInt(Opcode.add));
        assert(a == .list or b == .list);
        return lists_of(context.story).binary(opcode, a, b);
    }

    pub fn list_unary(context: *NativeContext, opcode: Opcode, a: Value) native.Error!Value {
        assert(@backingInt(opcode) >= @backingInt(Opcode.add));
        assert(a == .list);
        return lists_of(context.story).unary(opcode, a);
    }
};

// Variables (ink's VariablesState).

/// What ink's GetRawVariableWithName finds: a global or a list item for context 0 or -1,
/// then a temp (`frame_temp`). The name's class (`Program.name_classes`) says which, with
/// one read. Allocates nothing.
const RawVariable = union(enum) { value: Value, list_item: ListItemIndex, none };

fn raw_lookup(story: *Story, name: StringId, context: i32) RawVariable {
    assert(!name.is_none());
    assert(context >= -1);
    if (context == 0 or context == -1) {
        const class = story.program.name_class(name);
        switch (class.kind) {
            .global => return .{ .value = story.state.globals[class.index] },
            .list_item => return .{ .list_item = .from_int(class.index) },
            .none => {},
            _ => unreachable,
        }
    }
    const value = frame_temp(story, name, context) orelse return .none;
    return .{ .value = value };
}

/// The temp `name` in the frame of `context` (0 and -1: the current one), or null.
fn frame_temp(story: *Story, name: StringId, context: i32) ?Value {
    assert(!name.is_none());
    const stack = &story.state.call_stack;
    assert(stack.depth() > 0);
    if (context > @as(i32, @intCast(stack.depth()))) return null;
    return stack.temp_get(name, if (context == 0) -1 else context);
}

/// ink's GetRawVariableWithName; a list item's name gives a one-item list.
fn raw_variable(story: *Story, name: StringId, context: i32) Error!?Value {
    return switch (raw_lookup(story, name, context)) {
        .value => |value| value,
        .list_item => |item| try single_item_list(story, item),
        .none => null,
    };
}

/// The variable pointer `raw_variable` would return, or null when it would return anything
/// else; allocates nothing. A list item's name is never a pointer.
fn raw_pointer(story: *Story, name: StringId, context: i32) ?value_module.VariablePointer {
    const found = raw_lookup(story, name, context);
    if (found != .value or found.value != .variable_pointer) return null;
    return found.value.variable_pointer;
}

/// The global slot `name` names, if it names a global.
fn global_of(story: *const Story, name: StringId) ?GlobalSlot {
    const class = story.program.name_class(name);
    if (class.kind != .global) return null;
    assert(story.program.globals[class.index].name == name);
    return .from_int(class.index);
}

/// List item `item` as a one-item list (ink's FindSingleItemListWithName).
fn single_item_list(story: *Story, item: ListItemIndex) Error!Value {
    assert(item.to_int() < story.program.list_items.len);
    const origin = story.program.list_items[item.to_int()].origin;
    const reference = story.state.store_list(&.{item}, &.{origin}, &.{}) catch
        return error.ListLimit;
    return .{ .list = reference };
}

/// ink's GetVariableWithName: the variable's value, following variable pointers.
pub fn variable_value(story: *Story, name: StringId, context: i32) Error!?Value {
    assert(!name.is_none());
    const value = try raw_variable(story, name, context) orelse return null;
    return follow_pointers(story, value);
}

/// `value`, or the value its variable pointers lead to (null when one names nothing).
fn follow_pointers(story: *Story, start: Value) Error!?Value {
    var value = start;
    var hops: u32 = 0;
    while (value == .variable_pointer) : (hops += 1) {
        if (hops == story.state.limits.frames_max) return fail(story, .variable_pointer_cycle, .{});
        const pointer = value.variable_pointer;
        value = try raw_variable(story, pointer.name, pointer.context) orelse return null;
    }
    assert(value != .variable_pointer);
    return value;
}

/// The global in `slot`, read through the slot: ink's GetVariableWithName finds the same
/// global by its name. Only a variable pointer stored there follows ink's pointer rules.
pub fn global_value(story: *Story, slot: GlobalSlot) Error!Value {
    assert(slot.to_int() < story.program.globals.len);
    const stored = story.state.globals[slot.to_int()];
    if (stored != .variable_pointer) return stored;
    const value = try follow_pointers(story, stored) orelse return .{ .integer = 0 };
    assert(value != .variable_pointer);
    return value;
}

/// `VAR?` of a name that isn't a global: a temp or a list item, else ink's warning and 0.
pub fn temp_value(story: *Story, name: StringId) Error!Value {
    assert(!name.is_none());
    if (try variable_value(story, name, -1)) |value| return value;
    warn_name(story, .variable_not_found, name);
    assert(story.state.has_warning());
    return .{ .integer = 0 };
}

/// ink's ResolveVariablePointer, for a pointer stored by a declaration.
fn resolve_variable_pointer(story: *Story, pointer: value_module.VariablePointer) Error!Value {
    assert(!pointer.name.is_none());
    assert(pointer.context >= -1);
    var context = pointer.context;
    if (context == -1) {
        context = if (global_of(story, pointer.name) != null)
            0
        else
            @as(i32, @intCast(story.state.call_stack.depth())) - 1;
    }
    const pointed = try raw_variable(story, pointer.name, context);
    if (pointed) |value| if (value == .variable_pointer) return value;
    return .{ .variable_pointer = .{ .name = pointer.name, .context = context } };
}

pub fn declare_global(story: *Story, slot: GlobalSlot, value: Value) Error!void {
    assert(slot.to_int() < story.state.globals.len);
    assert(value != .tag);
    var stored = value;
    if (value == .variable_pointer) stored = try resolve_variable_pointer(
        story,
        value.variable_pointer,
    );
    try set_global(story, slot, stored);
}

pub fn declare_temp(story: *Story, name: StringId, value: Value) Error!void {
    assert(!name.is_none());
    assert(value != .tag);
    var stored = value;
    if (value == .variable_pointer) stored = try resolve_variable_pointer(
        story,
        value.variable_pointer,
    );
    const old = story.state.call_stack.temp_get(name, -1);
    stored = try retain_list_origins(story, old, stored);
    story.state.call_stack.temp_set(name, stored, true, -1) catch |err| switch (err) {
        error.TempNotFound => unreachable,
        else => return error.TempLimit,
    };
}

/// A re-assignment of the global in `slot`, through the slot (`set_global` keeps the
/// lookahead's undo log). Only a variable pointer stored there follows ink's pointer rules,
/// by name.
pub fn assign_global(story: *Story, slot: GlobalSlot, value: Value) Error!void {
    assert(slot.to_int() < story.program.globals.len);
    assert(value != .tag);
    if (story.state.globals[slot.to_int()] != .variable_pointer) {
        return set_global(story, slot, value);
    }
    const name = story.program.globals[slot.to_int()].name;
    try assign_existing(story, name, true, value);
}

pub fn assign_temp(story: *Story, name: StringId, value: Value) Error!void {
    assert(!name.is_none());
    assert(value != .tag);
    try assign_existing(story, name, global_of(story, name) != null, value);
}

/// ink's Assign for a re-assignment: follow pointers to the variable they name, then set it.
fn assign_existing(
    story: *Story,
    start_name: StringId,
    start_global: bool,
    value: Value,
) Error!void {
    assert(!start_name.is_none());
    assert(value != .tag);
    var name = start_name;
    var context: i32 = -1;
    var is_global = start_global;
    var hops: u32 = 0;
    // `value` was popped, so nothing roots it: this walk must not allocate (raw_variable
    // would make a one-item list for a list item's name, and that may compact).
    while (raw_pointer(story, name, context)) |pointer| : (hops += 1) {
        if (hops == story.state.limits.frames_max) return fail(story, .variable_pointer_cycle, .{});
        name = pointer.name;
        context = pointer.context;
        is_global = context == 0;
    }
    if (is_global) {
        const slot = global_of(story, name) orelse return fail(
            story,
            .variable_not_found,
            .{ .name = name },
        );
        return set_global(story, slot, value);
    }
    // ink's SetTemporaryVariable keeps list origins from the temp's own old value.
    const old = frame_temp(story, name, context);
    const stored = try retain_list_origins(story, old, value);
    story.state.call_stack.temp_set(name, stored, false, context) catch |err| switch (err) {
        error.TempNotFound => return fail(story, .temp_not_found, .{ .name = name }),
        else => return error.TempLimit,
    };
}

/// ink's SetGlobal. A changed observed global notifies its observers at once, or at the end
/// of `cont()` while it batches them.
pub fn set_global(story: *Story, slot: GlobalSlot, value: Value) Error!void {
    assert(slot.to_int() < story.state.globals.len);
    const old = story.state.globals[slot.to_int()];
    const stored = try retain_list_origins(story, old, value);
    lookahead.set_global(&story.state, slot, stored) catch return error.LookaheadLogLimit;
    assert(story.state.globals[slot.to_int()] == std.meta.activeTag(stored));
    // ink compares the old and new value objects by reference; identical values are the
    // closest a value representation gets (a reassigned literal is the same object in ink too).
    if (old.identical(stored) or !story_module.is_observed(story, slot)) return;
    if (!story.batching_observers) return story_module.notify_global(story, slot);
    const queue = &story.state.observer_events;
    if (std.mem.indexOfScalar(GlobalSlot, queue.slice(), slot) != null) return;
    queue.push(slot) catch return error.ObserverQueueLimit;
}

/// ink's RetainListOriginsForAssignment: an empty list assigned over a list keeps the old
/// list's origins.
fn retain_list_origins(story: *Story, old: ?Value, value: Value) Error!Value {
    assert(value != .tag);
    const previous = old orelse return value;
    if (previous != .list or value != .list) return value;
    if (lists_of(story).count(value.list) != 0) return value;
    var keep = [_]Value{ previous, value };
    try reserve_list(story, &keep);
    return lists_of(story).empty_with_origins_of(keep[0].list) catch |err| list_error(err);
}

pub fn list_literal(story: *Story, instruction: Instruction) Error!ListReference {
    assert(instruction.opcode == .list);
    const at = @backingInt(instruction.get(.list));
    const record = extra.get(instruction_module.ListLiteral, story.program.extra, at);
    const words = story.program.extra[at + extra.words(instruction_module.ListLiteral) ..];
    const items: []const ListItemIndex = @ptrCast(words[0..record.items_count]);
    const origin_words = words[record.items_count..][0..record.origins_count];
    const origins: []const ListOriginIndex = @ptrCast(origin_words);
    return story.state.store_list(items, origins, &.{}) catch error.ListLimit;
}

// Choices.

/// ink's ProcessChoice: pops what the choice point says it has, and adds the choice unless
/// it's hidden.
pub fn process_choice(
    story: *Story,
    record: instruction_module.ChoicePoint,
    pointer: Pointer,
) Error!void {
    assert(!pointer.is_null());
    assert(!record.target_container.is_none());
    var show = true;
    if (record.flags.has_condition) {
        if (!try truth_of(story, try vm.pop_evaluation(story))) show = false;
    }
    var popped: ChoicePops = .{};
    if (record.flags.has_choice_only_content) try popped.take(story, 1);
    if (record.flags.has_start_content) try popped.take(story, 0);
    const target: Pointer = .{ .container = record.target_container, .index = record.target_index };
    if (record.flags.once_only and vm.visit_count(story, target.container) > 0) show = false;
    if (!show) return;
    const text = try popped.text(story);
    const choice: choices_module.Choice = .{
        .text = text,
        .target = target,
        .source = pointer,
        .original_thread = 0,
        .thread_counter = 0,
        .tags_first = 0,
        .snapshot = 0,
        .tags_count = 0,
        .invisible_default = record.flags.is_invisible_default,
    };
    var tags: [ChoicePops.tags_max]StringReference = undefined;
    const tags_count = popped.tag_references(&tags);
    story.state.choices.add(&story.state.call_stack, choice, tags[0..tags_count]) catch |err|
        return err;
}

/// The strings and tags a choice point pops, kept as values so compaction updates them.
const ChoicePops = struct {
    pub const tags_max = 32;
    /// [0] start text, [1] choice-only text, then tags in order.
    values: [2 + tags_max]Value = @splat(.null),
    tags_count: u32 = 0,

    /// ink's PopChoiceStringAndTags; each call's tags go before the ones popped earlier.
    fn take(pops: *ChoicePops, story: *Story, slot: u32) Error!void {
        assert(slot < 2);
        const popped = try vm.pop_evaluation(story);
        if (popped != .string) return fail(story, .choice_text_not_string, .{});
        pops.values[slot] = popped;
        var popped_tags: u32 = 0;
        while (story.state.evaluation.peek()) |top| : (popped_tags += 1) {
            if (top != .tag) break;
            if (pops.tags_count == tags_max) return error.TagLimit;
            const tag = story.state.evaluation.pop().?;
            const kept = pops.values[2..];
            std.mem.copyBackwards(Value, kept[1 .. pops.tags_count + 1], kept[0..pops.tags_count]);
            kept[0] = tag;
            pops.tags_count += 1;
        }
        assert(popped_tags <= pops.tags_count);
    }

    fn part(pops: *const ChoicePops, story: *Story, slot: u32) []const u8 {
        assert(pops.values[slot] == .string or pops.values[slot] == .null);
        assert(slot < 2);
        const value = pops.values[slot];
        return if (value == .string) strings_of(story).get(value.string) else "";
    }

    /// `(start + choice_only).Trim(' ', '\t')`, reusing a string when nothing changes.
    fn text(pops: *ChoicePops, story: *Story) Error!StringReference {
        assert(pops.tags_count <= tags_max);
        assert(pops.values[0] != .tag and pops.values[1] != .tag);
        const blank = " \t";
        const start = pops.part(story, 0);
        const only = pops.part(story, 1);
        const start_trimmed = std.mem.trim(u8, start, blank).len == start.len;
        const only_trimmed = std.mem.trim(u8, only, blank).len == only.len;
        if (only.len == 0 and pops.values[0] == .string and start_trimmed) {
            return pops.values[0].string;
        }
        if (start.len == 0 and pops.values[1] == .string and only_trimmed) {
            return pops.values[1].string;
        }
        const total: u32 = @intCast(start.len + only.len);
        const reference = story.state.allocate_string(total, &pops.values) catch
            return error.HeapLimit;
        // The parts may have moved; read them again.
        const target = story.state.strings.get(reference);
        const start_now = pops.part(story, 0);
        @memcpy(target[0..start_now.len], start_now);
        @memcpy(target[start_now.len..], pops.part(story, 1));
        const trimmed = std.mem.trim(u8, target, blank);
        const leading: u32 = @intCast(std.mem.indexOf(u8, target, trimmed) orelse 0);
        std.mem.copyForwards(u8, target[0..trimmed.len], target[leading..][0..trimmed.len]);
        story.state.strings.shrink_last(reference, @intCast(trimmed.len));
        return reference;
    }

    fn tag_references(pops: *const ChoicePops, out: *[tags_max]StringReference) u32 {
        assert(out.len == tags_max);
        assert(pops.tags_count <= tags_max);
        for (pops.values[2..][0..pops.tags_count], 0..) |tag, position| out[position] = tag.tag;
        return pops.tags_count;
    }
};

// Counts, randomness and the ends of flow.

pub fn turns_since(story: *Story, container: ContainerIndex) i32 {
    assert(container.to_int() < story.program.containers.len);
    assert(story.state.turn_indices.len == story.state.visit_counts.len);
    const info = story.program.container_info(container);
    if (info.count_slot == container_module.no_count_slot) return -1;
    const recorded = story.state.turn_indices[info.count_slot];
    if (recorded == state_module.never_visited) return -1;
    return story.state.turn_index -% recorded;
}

pub fn random(story: *Story) Error!void {
    const maximum = try vm.pop_evaluation(story);
    const minimum = try vm.pop_evaluation(story);
    if (minimum != .integer) return fail(story, .random_invalid_minimum, .{});
    if (maximum != .integer) return fail(story, .random_invalid_maximum, .{});
    const range_wide = @as(i64, maximum.integer) - minimum.integer + 1;
    if (range_wide > std.math.maxInt(i32)) return fail(story, .random_range_too_large, .{});
    if (range_wide <= 0) {
        return fail(
            story,
            .random_range_empty,
            .{ .numbers = .{ minimum.integer, maximum.integer } },
        );
    }
    const range: i32 = @intCast(range_wide);
    const state = &story.state;
    var generator = DotnetRandom.init(state.story_seed +% state.previous_random);
    const next = generator.next();
    const chosen = @rem(next, range) +% minimum.integer;
    try vm.push_evaluation(story, .{ .integer = chosen });
    state.previous_random = next;
}

pub fn seed_random(story: *Story) Error!void {
    const seed = try vm.pop_evaluation(story);
    if (seed != .integer) return fail(story, .seed_invalid, .{});
    story.state.story_seed = seed.integer;
    story.state.previous_random = 0;
    try vm.push_evaluation(story, .null);
}

pub const shuffle_elements_max = 1024;

/// ink's NextSequenceShuffleIndex. A shuffle of more than `shuffle_elements_max` elements
/// returns ShuffleLimit.
pub fn sequence_shuffle_index(story: *Story) Error!void {
    assert(shuffle_elements_max > 0);
    assert(!vm.current_pointer(story).is_null());
    const elements_value = try vm.pop_evaluation(story);
    if (elements_value != .integer) return fail(story, .shuffle_invalid, .{});
    const sequence_count_value = try vm.pop_evaluation(story);
    if (sequence_count_value != .integer) return fail(story, .shuffle_invalid, .{});
    const elements = elements_value.integer;
    if (elements <= 0) return fail(story, .shuffle_invalid, .{});
    // ink has no bound; the unpicked indices live in a fixed buffer here.
    if (elements > shuffle_elements_max) return error.ShuffleLimit;
    const count = sequence_count_value.integer;
    const loop_index = @divTrunc(count, elements);
    const iteration_index = @rem(count, elements);
    const container = vm.current_pointer(story).container;
    const hash: i32 = @bitCast(story.program.container_info(container).path_hash);
    var generator = DotnetRandom.init(hash +% loop_index +% story.state.story_seed);
    var unpicked: [shuffle_elements_max]i32 = undefined;
    var unpicked_count: u32 = @intCast(elements);
    for (unpicked[0..unpicked_count], 0..) |*slot, position| slot.* = @intCast(position);
    var round: i32 = 0;
    while (round <= iteration_index) : (round += 1) {
        const chosen: u32 = @intCast(@rem(generator.next(), @as(i32, @intCast(unpicked_count))));
        const picked = unpicked[chosen];
        std.mem.copyForwards(
            i32,
            unpicked[chosen .. unpicked_count - 1],
            unpicked[chosen + 1 .. unpicked_count],
        );
        unpicked_count -= 1;
        if (round == iteration_index) return vm.push_evaluation(story, .{ .integer = picked });
    }
    unreachable;
}

pub fn done(story: *Story) Error!void {
    assert(story.state.call_stack.depth() > 0);
    const stack = &story.state.call_stack;
    if (stack.can_pop_thread()) {
        stack.pop_thread() catch unreachable;
        return;
    }
    story.state.did_safe_exit = true;
    stack.current_frame().pointer = .null;
    assert(vm.current_pointer(story).is_null());
}

/// ink's ForceEnd (`END`): the call stack and the choices go.
pub fn force_end(story: *Story) void {
    const state = &story.state;
    state.call_stack.reset(.start_of(story.program.root_container()));
    state.choices.clear();
    state.call_stack.current_frame().pointer = .null;
    state.call_stack.current_thread().previous_pointer = .null;
    state.did_safe_exit = true;
    assert(vm.current_pointer(story).is_null());
}

pub fn list_command(story: *Story, opcode: Opcode) Error!void {
    assert(opcode == .list_from_int or opcode == .list_range or opcode == .list_random);
    const value = switch (opcode) {
        .list_from_int => try list_from_int(story),
        .list_range => try list_range(story),
        .list_random => try list_random(story),
        else => unreachable,
    };
    try vm.push_evaluation(story, value);
}

fn list_error(err: lists_module.Error) Error {
    assert(err != error.DivisionByZero);
    assert(@errorName(err).len > 0);
    return switch (err) {
        error.ListLimit => error.ListLimit,
        error.HeapLimit => error.HeapLimit,
        else => unreachable,
    };
}

/// `"listInt"`: the list item named by a list name and a value.
fn list_from_int(story: *Story) Error!Value {
    const number = try vm.pop_evaluation(story);
    var keep = [_]Value{try vm.pop_evaluation(story)};
    if (number != .integer) return fail(story, .list_from_int_not_int, .{});
    if (keep[0] != .string) return fail(story, .list_not_found, .{});
    try reserve_list(story, &keep);
    const name = strings_of(story).get(keep[0].string);
    const lists = lists_of(story);
    const result = lists.from_int(name, number.integer) catch |err| return list_error(err);
    assert(result == null or result.? == .list);
    return result orelse fail(story, .list_not_found, .{});
}

/// LIST_RANGE(list, min, max).
fn list_range(story: *Story) Error!Value {
    var keep: [3]Value = undefined;
    keep[2] = try vm.pop_evaluation(story);
    keep[1] = try vm.pop_evaluation(story);
    keep[0] = try vm.pop_evaluation(story);
    if (keep[0] != .list or keep[1] == .null or keep[2] == .null) {
        return fail(story, .list_range_arguments, .{});
    }
    try reserve_list(story, &keep);
    const result = lists_of(story).sub_range(keep[0].list, keep[1], keep[2]) catch |err|
        return list_error(err);
    assert(result == .list);
    return result;
}

/// LIST_RANDOM(list): one item, drawn like RANDOM.
fn list_random(story: *Story) Error!Value {
    var keep = [_]Value{try vm.pop_evaluation(story)};
    if (keep[0] != .list) return fail(story, .list_random_not_list, .{});
    try reserve_list(story, &keep);
    const lists = lists_of(story);
    const count = lists.count(keep[0].list);
    if (count == 0) {
        return .{ .list = story.state.lists.store(&.{}, &.{}) catch return error.ListLimit };
    }
    const state = &story.state;
    var generator = DotnetRandom.init(state.story_seed +% state.previous_random);
    const next = generator.next();
    const position: u32 = @intCast(@rem(next, @as(i32, @intCast(count))));
    const result = lists.item_list(keep[0].list, position) catch |err| return list_error(err);
    state.previous_random = next;
    assert(result == .list);
    return result;
}

/// Room for one list of any size, compacting (and updating `keep`) if needed.
fn reserve_list(story: *Story, keep: []Value) Error!void {
    assert(keep.len <= 3);
    const state = &story.state;
    const program = story.program;
    const words: u32 = @intCast(3 + program.list_items.len + program.list_origins.len);
    const short = state.lists.words.len - state.lists.used < words;
    if (short or state.compact_always) state.compact(keep);
    state.lists.note_need(words);
    if (state.lists.words.len - state.lists.used < words) return error.ListLimit;
    assert(state.lists.used + words <= state.lists.words.len);
}

/// ink's CallExternalFunction (with the conditional divert check before it).
pub fn call_external(story: *Story, instruction: Instruction) Error!vm.Signal {
    assert(story.bindings.len == story.program.externals.len);
    assert(instruction.opcode == .call_external);
    const at = @backingInt(instruction.get(.call_external));
    const record = extra.get(instruction_module.ExternalCall, story.program.extra, at);
    if (record.flags.conditional) {
        if (!try truth_of(story, try vm.pop_evaluation(story))) return .none;
    }
    const external = record.external.to_int();
    const binding = story.bindings[external];
    if (binding.function != null and !binding.lookahead_safe) {
        if (story.state.output.in_string_evaluation()) {
            return fail(
                story,
                .external_unsafe_in_string,
                .{ .name = story.program.externals[external].name },
            );
        }
        // Under an outer level's snapshot (a function evaluated from a lookahead-safe
        // external), the call runs now; RunningYourInk.md says why that can repeat.
        if (story_module.owns_lookahead(story)) {
            // The line ends at the snapshot; the call runs on the next `cont`.
            story.saw_lookahead_unsafe_function_after_newline = true;
            return .output;
        }
    }
    const function = binding.function orelse return call_fallback(story, external);
    try call_bound(story, function, binding.context, record.arguments_count);
    return .none;
}

fn call_fallback(story: *Story, external: u32) Error!vm.Signal {
    assert(story.bindings[external].function == null);
    assert(external < story.program.externals.len);
    const info = story.program.externals[external];
    if (!story.allow_external_function_fallbacks) {
        return fail(story, .external_not_bound, .{ .name = info.name });
    }
    if (info.fallback.is_none()) return fail(
        story,
        .external_fallback_missing,
        .{ .name = info.name },
    );
    const state = &story.state;
    state.call_stack.push(.function, state.evaluation.count, state.output.items.count) catch
        return error.FrameLimit;
    story.diverted_pointer = .start_of(info.fallback);
    return .none;
}

/// Calls a bound external with the top `count` values as arguments (a view of the stack),
/// then replaces them with its result.
fn call_bound(
    story: *Story,
    function: story_module.ExternalFunction,
    context: ?*anyopaque,
    count: u32,
) Error!void {
    const state = &story.state;
    if (count > story_module.external_arguments_max) return fail(story, .too_many_arguments, .{});
    if (state.evaluation.count < count) return fail(story, .evaluation_stack_empty, .{});
    var arguments: [story_module.external_arguments_max]story_module.HostValue = undefined;
    const first = state.evaluation.count - count;
    for (state.evaluation.slice()[first..], 0..) |value, position| {
        arguments[position] = host_value(story, value);
    }
    story.callback_depth += 1;
    defer story.callback_depth -= 1;
    // Only an external function may call evaluate_function (`Story.may_evaluate`).
    const external_callback_depth = story.external_callback_depth;
    story.external_callback_depth = story.callback_depth;
    defer story.external_callback_depth = external_callback_depth;
    const result = function(context, story, arguments[0..count]) catch
        return error.ExternalFunctionFailed;
    assert(state.evaluation.count >= first + count);
    state.evaluation.count = first;
    try vm.push_evaluation(story, try value_of_host(story, result));
}

/// A value as the host sees it (ink's valueObject).
pub fn host_value(story: *Story, value: Value) story_module.HostValue {
    return switch (value) {
        .null, .variable_pointer, .tag => .null,
        .integer => |number| .{ .integer = number },
        .float => |number| .{ .float = number },
        .bool => |flag| .{ .bool = flag },
        .string => |reference| .{ .string = strings_of(story).get(reference) },
        .list => |list| .{ .list = list },
        .divert_target => |target| .{ .divert_target = target },
    };
}

/// Host values as ink values, with strings copied into the heap. Each allocation may
/// compact the heap, which would move a later argument's text if it is in the heap (a
/// string from `get_variable`, say), so all such texts are copied out into the line buffer
/// before the first allocation; the other values are kept through compaction.
pub fn values_of_host(
    story: *Story,
    hosts: []const story_module.HostValue,
    values: []Value,
) Error!void {
    assert(hosts.len == values.len);
    var copies: [story_module.external_arguments_max]story_module.HostValue = undefined;
    assert(hosts.len <= copies.len);
    const line_bytes = story.state.line_bytes;
    var used: u32 = 0;
    for (hosts, 0..) |host, position| {
        copies[position] = host;
        if (host != .string or !in_heap(story, host.string)) continue;
        const text = host.string;
        if (text.len > line_bytes.len - used) return error.OutputLimit;
        const copy = line_bytes[used..][0..text.len];
        @memcpy(copy, text);
        copies[position] = .{ .string = copy };
        used += @intCast(text.len);
    }
    note_line_bytes(&story.state, used);
    // Every other value first (a list reference moves with the heap too), then each
    // string, keeping all of them through the compaction it may cause.
    for (copies[0..hosts.len], values) |host, *value| {
        value.* = if (host == .string) .null else try value_of_host(story, host);
    }
    for (copies[0..hosts.len], values) |host, *value| {
        if (host != .string) continue;
        assert(!in_heap(story, host.string));
        // Into a local first: assigning the call's result straight into `value.*` may set
        // its tag to `.string` before the call, and the call keeps `values`, so a
        // compaction would visit a garbage reference.
        const reference = try store_string(story, host.string, values);
        value.* = .{ .string = reference };
    }
}

/// A host value as an ink value; strings are copied into the heap.
pub fn value_of_host(story: *Story, host: story_module.HostValue) Error!Value {
    return switch (host) {
        .null => .null,
        .integer => |number| .{ .integer = number },
        .float => |number| .{ .float = number },
        .bool => |flag| .{ .bool = flag },
        .string => |text| .{ .string = try store_string(story, text, &.{}) },
        .list => |list| .{ .list = list },
        .divert_target => |target| .{ .divert_target = target },
    };
}
