//! Diagnostic messages: the text ink gives each runtime error and warning, without the
//! prefix `State.add_diagnostic` writes.

const std = @import("std");
const assert = std.debug.assert;
const value_module = @import("value.zig");
const story_module = @import("story.zig");
const ops = @import("ops.zig");
const Story = story_module.Story;
const Value = value_module.Value;
const Opcode = @import("../core/instruction.zig").Opcode;
const ink_json = @import("../core/ink_json.zig");

/// The text of the error `code` with `arguments`, for `State.add_diagnostic`'s "{f}".
pub const Text = struct {
    story: *const Story,
    code: Code,
    arguments: ops.Arguments,

    pub fn format(text: Text, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return write_text(text.story, text.code, text.arguments, writer);
    }
};

/// Filled in by the VM's error handling.
pub const Code = enum(u16) {
    story_error,
    evaluation_stack_empty,
    glue_in_expression,
    divert_variable_not_found,
    divert_variable_not_target,
    turns_since_expected_target,
    tunnel_return_not_target,
    pop_mismatch,
    /// ink's "Found <popped>, when expected <current>": `number` the popped FrameKind,
    /// `other_number` the current frame's, or 2 when the stack can't pop.
    pop_unexpected,
    unmatched_end_string,
    unexpected_command_in_tag,
    no_truth_value,
    division_by_zero,
    integer_overflow,
    float_to_integer_out_of_range,
    void_operand,
    unsupported_operation,
    /// ink's "Cannot perform operation": `number` the opcode, `other_number` the rank
    /// (`Value.rank`) of the type the operands were coerced to.
    operation_not_for_type,
    /// `number`: the opcode; `other_number`: the operands' Value tags, left << 8 | right.
    list_operand_types,
    variable_not_found,
    variable_pointer_cycle,
    temp_not_found,
    choice_text_not_string,
    random_invalid_minimum,
    random_invalid_maximum,
    random_range_too_large,
    random_range_empty,
    seed_invalid,
    shuffle_invalid,
    thread_left_to_pop,
    unexpected_end_of_tunnel,
    unexpected_end_of_function,
    ran_out_of_content,
    unexpected_end_unknown,
    list_from_int_not_int,
    list_not_found,
    list_range_arguments,
    list_random_not_list,
    external_unsafe_in_string,
    external_not_bound,
    external_fallback_missing,
    too_many_arguments,
    unsupported,
    _,
};

fn write_text(
    story: *const Story,
    code: Code,
    arguments: ops.Arguments,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    assert(story.state.memory.len > 0);
    const name = arguments.name;
    const argument = if (name.is_none()) "" else story.program.strings.get(name);
    const number = arguments.numbers[0];
    const other_number = arguments.numbers[1];
    assert(argument.len < 1 << 20);
    const text: []const u8 = switch (code) {
        .variable_not_found => return writer.print("Variable not found: '{s}'. Using default " ++
            "value of 0 (false). This can happen with temporary variables if the declaration " ++
            "hasn't yet been hit. Globals are always given a default value on load if a value " ++
            "doesn't exist in the save state.", .{argument}),
        .divert_variable_not_found => return writer.print("Tried to divert using a target from " ++
            "a variable that could not be found ({s})", .{argument}),
        .divert_variable_not_target => return write_not_target(story, arguments, argument, writer),
        .random_range_empty => return writer.print("RANDOM was called with minimum as {d} and " ++
            "maximum as {d}. The maximum must be larger", .{ number, other_number }),
        .external_not_bound => return writer.print("Trying to call EXTERNAL function '{s}' " ++
            "which has not been bound (and ink fallbacks disabled).", .{argument}),
        .external_fallback_missing => return writer.print("Trying to call EXTERNAL function " ++
            "'{s}' which has not been bound, and fallback ink function could not be found.", .{
            argument,
        }),
        .external_unsafe_in_string => return writer.print("External function {s} could not be " ++
            "called because 1) it wasn't marked as lookaheadSafe when BindExternalFunction was " ++
            "called and 2) the story is in the middle of string generation, either because " ++
            "choice text is being generated, or because you have ink like \"hello {{func()}}\". " ++
            "You can work around this by generating the result of your function into a " ++
            "temporary variable before the string or choice gets generated: ~ temp x = {s}()", .{
            argument,
            argument,
        }),
        .temp_not_found => return writer.print("Could not find temporary variable to set: " ++
            "{s}", .{argument}),
        .list_not_found => return writer.print("Failed to find LIST called {s}", .{argument}),
        .list_operand_types => return writer.print("Can not call use '{s}' operation on {s} " ++
            "and {s}", .{
            opcode_word(number),
            type_name(other_number >> 8),
            type_name(other_number & 0xff),
        }),
        .operation_not_for_type => return writer.print("Cannot perform operation '{s}' on {s}", .{
            opcode_word(number),
            rank_name(other_number),
        }),
        .pop_unexpected => return writer.print("Found {s}, when expected {s}", .{
            pop_name(number),
            pop_name(other_number),
        }),
        else => fixed_text(code),
    };
    try writer.writeAll(text);
}

/// What ink calls a function return, a tunnel onwards, or the end of a flow (a FrameKind
/// number, or 2 for the end).
fn pop_name(number: i32) []const u8 {
    assert(number >= 0 and number <= 2);
    return switch (number) {
        0 => "tunnel onwards statement (->->)",
        1 => "function return statement (~ return)",
        else => "end of flow (-> END or choice)",
    };
}

/// ink's ValueType name for a `Value.rank`.
fn rank_name(rank: i32) []const u8 {
    assert(rank >= 0 and rank <= 5);
    const names = [_][]const u8{
        "Int", "Float", "List", "String", "DivertTarget", "VariablePointer",
    };
    return names[@intCast(rank)];
}

/// ink's "didn't contain a divert target": `was empty/null (the value 0).` for an integer
/// 0, else `contained '<value>'.` with the value's ToString, which the failure stored as
/// `detail`.
fn write_not_target(
    story: *const Story,
    arguments: ops.Arguments,
    name: []const u8,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    try writer.print("Tried to divert to a target from a variable, but the variable ({s}) " ++
        "didn't contain a divert target, it ", .{name});
    if (arguments.detail == value_module.StringReference.none) {
        return writer.writeAll("was empty/null (the value 0).");
    }
    try writer.print("contained '{s}'.", .{ops.strings_of(story).get(arguments.detail)});
}

/// The native function's name as ink spells it (its JSON word), from an opcode number.
fn opcode_word(number: i32) []const u8 {
    const words = comptime table: {
        const fields = @typeInfo(Opcode).@"enum".field_names;
        var table: [fields.len][]const u8 = @splat("?");
        for (ink_json.words.keys(), ink_json.words.values()) |key, opcode| {
            table[@backingInt(opcode)] = key;
        }
        break :table table;
    };
    assert(number >= 0);
    const position: u32 = @intCast(number);
    assert(position < words.len);
    return words[position];
}

/// ink's ValueType name for a Value tag number, as its messages print it.
fn type_name(tag_number: i32) []const u8 {
    assert(tag_number >= 0);
    assert(tag_number <= std.math.maxInt(u8));
    const tag: std.meta.Tag(Value) = @fromBackingInt(@as(u8, @intCast(tag_number)));
    return switch (tag) {
        .null => "Void",
        .integer => "Int",
        .float => "Float",
        .bool => "Bool",
        .string, .tag => "String",
        .divert_target => "DivertTarget",
        .variable_pointer => "VariablePointer",
        .list => "List",
    };
}

fn fixed_text(code: Code) []const u8 {
    assert(code != .variable_not_found);
    assert(@backingInt(code) < std.math.maxInt(u16));
    return switch (code) {
        .thread_left_to_pop => "Thread available to pop, threads should always be flat by the " ++
            "end of evaluation?",
        .unexpected_end_of_tunnel => "unexpectedly reached end of content. Do you need a '->->' " ++
            "to return from a tunnel?",
        .unexpected_end_of_function => "unexpectedly reached end of content. Do you need a " ++
            "'~ return'?",
        .ran_out_of_content => "ran out of content. Do you need a '-> DONE' or '-> END'?",
        .unexpected_end_unknown => "unexpectedly reached end of content for unknown reason. " ++
            "Please debug compiler!",
        .random_invalid_minimum => "Invalid value for minimum parameter of RANDOM(min, max)",
        .random_invalid_maximum => "Invalid value for maximum parameter of RANDOM(min, max)",
        .random_range_too_large => "RANDOM was called with a range that exceeds the size that " ++
            "ink numbers can use.",
        .seed_invalid => "Invalid value passed to SEED_RANDOM",
        .shuffle_invalid => "expected number of elements in sequence for shuffle index",
        .list_from_int_not_int => "Passed non-integer when creating a list element from a " ++
            "numerical value.",
        .list_range_arguments => "Expected list, minimum and maximum for LIST_RANGE",
        .list_random_not_list => "Expected list for LIST_RANDOM",
        .turns_since_expected_target => "TURNS_SINCE expected a divert target (knot, stitch, " ++
            "label name)",
        .no_truth_value => "Shouldn't use a divert target as a conditional value. Did you " ++
            "intend a function call 'likeThis()' or a read count check 'likeThis'? (no arrows)",
        .void_operand => "Attempting to perform operation on a void value. Did you forget to " ++
            "'return' a value from a function you called here?",
        .division_by_zero => "Attempted to divide by zero.",
        .integer_overflow => "Integer overflow (minimum int divided by -1).",
        .float_to_integer_out_of_range => "A float out of the int range can't become an int.",
        .unsupported_operation => "Unsupported operation for these value types.",
        .pop_mismatch => "Found a return or tunnel onwards where it doesn't match the call stack.",
        .unexpected_command_in_tag => "Unexpected ControlCommand while extracting tag from choice",
        .evaluation_stack_empty => "trying to pop too many objects",
        .too_many_arguments => "Too many arguments for an external function.",
        else => "Story error.",
    };
}
