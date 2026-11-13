//! Diagnostic messages: the text ink gives each runtime error and warning, with
//! ink's prefix from Story.AddError. Compiled JSON has no debug metadata, so the prefix is
//! `RUNTIME ERROR: (<pointer path>): ` while the story has a pointer, else `RUNTIME ERROR: `.

const std = @import("std");
const assert = std.debug.assert;
const state_module = @import("state.zig");
const value_module = @import("value.zig");
const story_module = @import("story.zig");
const ops = @import("ops.zig");
const Story = story_module.Story;
const Diagnostic = state_module.Diagnostic;

pub fn write(story: *const Story, diagnostic: Diagnostic, writer: *std.Io.Writer) !void {
    assert(writer.buffer.len > 0);
    assert(@backingInt(diagnostic.code) < std.math.maxInt(u16));
    const kind = if (diagnostic.severity == .@"error") "ERROR" else "WARNING";
    try writer.print("RUNTIME {s}: ", .{kind});
    if (!diagnostic.pointer.is_null()) {
        const pointer = diagnostic.pointer;
        const path = story.program.strings.get(story.program.table().get(pointer.container).path);
        if (path.len == 0) {
            try writer.print("({d}): ", .{pointer.index});
        } else {
            try writer.print("({s}.{d}): ", .{ path, pointer.index });
        }
    }
    try write_text(story, diagnostic, writer);
}

fn write_text(story: *const Story, diagnostic: Diagnostic, writer: *std.Io.Writer) !void {
    assert(story.state.memory.len > 0);
    const argument = if (diagnostic.argument == value_module.StringReference.none)
        ""
    else
        ops.strings_of(story).get(diagnostic.argument);
    assert(argument.len < 1 << 20);
    const text: []const u8 = switch (diagnostic.code) {
        .variable_not_found => return writer.print("Variable not found: '{s}'. Using default " ++
            "value of 0 (false). This can happen with temporary variables if the declaration " ++
            "hasn't yet been hit. Globals are always given a default value on load if a value " ++
            "doesn't exist in the save state.", .{argument}),
        .divert_variable_not_found => return writer.print("Tried to divert using a target from " ++
            "a variable that could not be found ({s})", .{argument}),
        .divert_variable_not_target => return writer.print("Tried to divert to a target from a " ++
            "variable, but the variable ({s}) didn't contain a divert target, it was " ++
            "empty/null (the value 0).", .{argument}),
        .random_range_empty => return writer.print("RANDOM was called with minimum as {d} and " ++
            "maximum as {d}. The maximum must be larger", .{
            diagnostic.number,
            diagnostic.other_number,
        }),
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
        else => fixed_text(diagnostic.code),
    };
    try writer.writeAll(text);
}

fn fixed_text(code: Diagnostic.Code) []const u8 {
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
