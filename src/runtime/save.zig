//! Saving: ink's StoryState.ToJson, save format v10, streamed to a
//! writer with no allocation. The output is JSON-equivalent to C# ink's: the same keys
//! and values; object key order may differ.

const std = @import("std");
const assert = std.debug.assert;
const profile = @import("../core/profile.zig");
const container_module = @import("../core/container.zig");
const dotnet_float = @import("../core/dotnet_float.zig");
const value_module = @import("value.zig");
const output_module = @import("output.zig");
const call_stack_module = @import("call_stack.zig");
const choices_module = @import("choices.zig");
const state_module = @import("state.zig");
const flows = @import("flows.zig");
const lookahead = @import("lookahead.zig");
const ops = @import("ops.zig");
const story_module = @import("story.zig");
const Story = story_module.Story;
const text_of = story_module.text_of;
const path_of = story_module.path_of;
const Value = value_module.Value;
const Pointer = call_stack_module.Pointer;
const Program = @import("../core/program.zig").Program;
const instruction_module = @import("../core/instruction.zig");
const Instruction = instruction_module.Instruction;
const extra = @import("../core/extra.zig");
const Frame = call_stack_module.Frame;
const Temp = call_stack_module.Temp;
const Item = output_module.Item;
const Choice = choices_module.Choice;
const Writer = std.Io.Writer;
const ListItemIndex = @import("../core/index.zig").ListItemIndex;

pub const save_version = 10;
pub const format_version = 21;

/// One flow's buffers, live or not current.
const FlowView = struct {
    buffers: state_module.FlowBuffers,
    thread_counter: u32,
};

fn live_view(story: *Story) FlowView {
    const state = &story.state;
    return .{
        .buffers = state.live_flow(),
        .thread_counter = state.call_stack.thread_counter,
    };
}

fn other_view(story: *Story, flow: u32) FlowView {
    const record = &story.state.flows[flow];
    assert(record.in_use and flow != story.state.current_flow);
    return .{
        .buffers = flows.view(&story.state, flow),
        .thread_counter = record.thread_counter,
    };
}

/// ink's StoryState.ToJson. The state must not be inside a lookahead (call it between
/// `cont` calls).
pub fn to_json(story: *Story, writer: *Writer) Writer.Error!void {
    const profile_zone = profile.begin(.save_write);
    defer profile_zone.end();
    assert(!lookahead.active(&story.state));
    story.state.verify();
    try writer.writeAll("{\"flows\":{");
    for (story.state.flows, 0..) |*record, position| {
        if (!record.in_use) continue;
        if (position > 0) try writer.writeByte(',');
        try write_json_string(writer, record.name[0..record.name_length]);
        try writer.writeByte(':');
        const view = if (position == story.state.current_flow)
            live_view(story)
        else
            other_view(story, @intCast(position));
        try write_flow(story, writer, view);
    }
    try writer.writeAll("},\"currentFlowName\":");
    try write_json_string(writer, flows.current_name(&story.state));
    try writer.writeAll(",\"variablesState\":");
    try write_variables(story, writer);
    try writer.writeAll(",\"evalStack\":[");
    for (story.state.evaluation.slice(), 0..) |value, position| {
        if (position > 0) try writer.writeByte(',');
        try write_value(story, writer, value);
    }
    try writer.writeAll("],\"visitCounts\":");
    try write_counts(story, writer, .visits);
    try writer.writeAll(",\"turnIndices\":");
    try write_counts(story, writer, .turns);
    try writer.print(",\"turnIdx\":{d},\"storySeed\":{d},\"previousRandom\":{d}", .{
        story.state.turn_index, story.state.story_seed, story.state.previous_random,
    });
    try writer.print(",\"inkSaveVersion\":{d},\"inkFormatVersion\":{d}}}", .{
        save_version, format_version,
    });
}

/// The flows' first record is the default flow, written first as ink's dictionary does.
fn write_flow(story: *Story, writer: *Writer, view: FlowView) Writer.Error!void {
    assert(view.buffers.choices.len <= story.state.choices.records.capacity());
    assert(view.buffers.threads.len > 0);
    try writer.writeAll("{\"callstack\":{\"threads\":[");
    for (view.buffers.threads, 0..) |thread, position| {
        if (position > 0) try writer.writeByte(',');
        const frames = view.buffers.frames[thread.frame_first..][0..thread.frame_count];
        try write_thread(
            story,
            writer,
            frames,
            view.buffers.temps,
            thread.counter,
            thread.previous_pointer,
        );
    }
    try writer.print("],\"threadCounter\":{d}}},\"outputStream\":[", .{view.thread_counter});
    for (view.buffers.items, 0..) |item, position| {
        if (position > 0) try writer.writeByte(',');
        try write_item(story, writer, item);
    }
    try writer.writeByte(']');
    try write_choice_threads(story, writer, view);
    try writer.writeAll(",\"currentChoices\":[");
    for (view.buffers.choices, 0..) |choice, position| {
        if (position > 0) try writer.writeByte(',');
        try write_choice(story, writer, view, choice);
    }
    try writer.writeAll("]}");
}

/// ink's choiceThreads: the stored thread of each choice whose thread isn't live.
fn write_choice_threads(story: *Story, writer: *Writer, view: FlowView) Writer.Error!void {
    assert(view.buffers.snapshots.len <= story.state.choices.snapshots.capacity());
    var written = false;
    for (view.buffers.choices) |choice| {
        if (thread_is_live(view, choice.thread_counter)) continue;
        try writer.writeAll(if (written) "," else ",\"choiceThreads\":{");
        written = true;
        const snapshot = view.buffers.snapshots[choice.snapshot];
        const frames =
            view.buffers.snapshot_frames[snapshot.frames_first..][0..snapshot.frames_count];
        try writer.print("\"{d}\":", .{choice.thread_counter});
        try write_thread(
            story,
            writer,
            frames,
            view.buffers.snapshot_temps,
            choice.thread_counter,
            snapshot.previous_pointer,
        );
    }
    if (written) try writer.writeByte('}');
}

fn thread_is_live(view: FlowView, counter: u32) bool {
    for (view.buffers.threads) |thread| {
        if (thread.counter == counter) return true;
    }
    return false;
}

fn write_thread(
    story: *Story,
    writer: *Writer,
    frames: []const Frame,
    temps: []const Temp,
    counter: u32,
    previous: Pointer,
) Writer.Error!void {
    assert(frames.len > 0);
    try writer.writeAll("{\"callstack\":[");
    for (frames, 0..) |frame, position| {
        if (position > 0) try writer.writeByte(',');
        try writer.writeByte('{');
        if (!frame.pointer.is_null()) {
            try writer.writeAll("\"cPath\":");
            try write_json_string(writer, path_of(story, frame.pointer.container));
            try writer.print(",\"idx\":{d},", .{frame.pointer.index});
        }
        try writer.print("\"exp\":{s},\"type\":{d}", .{
            if (frame.in_expression_evaluation) "true" else "false",
            @backingInt(frame.kind),
        });
        if (frame.temps_count > 0) {
            try writer.writeAll(",\"temp\":{");
            for (temps[frame.temps_first..][0..frame.temps_count], 0..) |temp, offset| {
                if (offset > 0) try writer.writeByte(',');
                try write_json_string(writer, story.program.strings.get(temp.name));
                try writer.writeByte(':');
                try write_value(story, writer, temp.value);
            }
            try writer.writeByte('}');
        }
        try writer.writeByte('}');
    }
    try writer.print("],\"threadIndex\":{d}", .{counter});
    if (!previous.is_null()) {
        try writer.writeAll(",\"previousContentObject\":");
        try write_object_path(story, writer, previous);
    }
    try writer.writeByte('}');
}

/// The path of the content object at `pointer` (ink's `pointer.Resolve().path`): a nested
/// container's own path, or the container's path and the index.
fn write_object_path(story: *Story, writer: *Writer, pointer: Pointer) Writer.Error!void {
    assert(!pointer.is_null());
    const program = story.program;
    // ink's Pointer.Resolve gives the container itself for its own index and for an empty
    // container.
    const empty = program.content_count(pointer.container) == 0;
    if (pointer.index == Pointer.container_self or empty) {
        return write_json_string(writer, path_of(story, pointer.container));
    }
    if (pointer.index < program.content_count(pointer.container)) {
        if (program.container_at(pointer.container, pointer.index)) |child| {
            return write_json_string(writer, path_of(story, child));
        }
    }
    const index = ink_content_index(program, pointer);
    const path = path_of(story, pointer.container);
    if (path.len == 0) return writer.print("\"{d}\"", .{index});
    try writer.writeByte('"');
    try write_escaped(writer, path);
    try writer.print(".{d}\"", .{index});
}

/// The content index ink's `Object.path` gives the object at `pointer`. ink finds an object's
/// index with `content.IndexOf(this)`, which compares with `Equals`, and a Divert is equal to
/// any divert with the same target (or the same variable): so a divert's path is the first
/// equal divert's in its container (P16.21).
fn ink_content_index(program: *const Program, pointer: Pointer) u32 {
    assert(pointer.index < program.content_count(pointer.container));
    const at = program.instruction_at(pointer.container, pointer.index);
    if (at.opcode != .divert) return pointer.index;
    const target = divert_of(program, at);
    for (0..pointer.index) |position| {
        const earlier = program.instruction_at(pointer.container, @intCast(position));
        if (earlier.opcode != .divert) continue;
        const other = divert_of(program, earlier);
        if (other.flags.variable != target.flags.variable) continue;
        const same = if (target.flags.variable)
            other.name == target.name
        else
            other.target_container == target.target_container and
                other.target_index == target.target_index;
        if (same) return @intCast(position);
    }
    return pointer.index;
}

fn divert_of(program: *const Program, instruction: Instruction) instruction_module.Divert {
    assert(instruction.opcode == .divert);
    const at = @backingInt(instruction.get(.divert));
    return extra.get(instruction_module.Divert, program.extra, at);
}

fn write_item(story: *Story, writer: *Writer, item: Item) Writer.Error!void {
    switch (item.kind) {
        .text => {
            if (item.class == .newline) return writer.writeAll("\"\\n\"");
            try writer.writeAll("\"^");
            try write_escaped(writer, item.bytes(ops.strings_of(story)));
            try writer.writeByte('"');
        },
        .glue => try writer.writeAll("\"<>\""),
        .begin_string => try writer.writeAll("\"str\""),
        .begin_tag => try writer.writeAll("\"#\""),
        .end_tag => try writer.writeAll("\"/#\""),
        .tag => {
            try writer.writeAll("{\"#\":");
            try write_json_string(writer, item.bytes(ops.strings_of(story)));
            try writer.writeByte('}');
        },
    }
}

fn write_choice(
    story: *Story,
    writer: *Writer,
    view: FlowView,
    choice: Choice,
) Writer.Error!void {
    assert(choice.tags_first + choice.tags_count <= view.buffers.tags.len);
    try writer.writeAll("{\"text\":");
    try write_json_string(writer, text_of(story, choice.text));
    try writer.print(",\"index\":{d},\"originalChoicePath\":", .{choice.index});
    try write_object_path(story, writer, choice.source);
    try writer.print(",\"originalThreadIndex\":{d},\"targetPath\":", .{choice.thread_counter});
    try write_target_path(story, writer, choice.target);
    if (choice.tags_count > 0) {
        try writer.writeAll(",\"tags\":[");
        for (view.buffers.tags[choice.tags_first..][0..choice.tags_count], 0..) |tag, position| {
            if (position > 0) try writer.writeByte(',');
            try write_json_string(writer, text_of(story, tag));
        }
        try writer.writeByte(']');
    }
    try writer.writeByte('}');
}

/// A choice target: a container's path when it targets its start, else the item's path.
fn write_target_path(story: *Story, writer: *Writer, target: Pointer) Writer.Error!void {
    assert(!target.is_null());
    if (target.index == 0) return write_json_string(writer, path_of(story, target.container));
    try write_object_path(story, writer, target);
}

/// ink writes only globals that differ from their defaults.
fn write_variables(story: *Story, writer: *Writer) Writer.Error!void {
    const state = &story.state;
    assert(state.globals.len == state.global_defaults.len);
    try writer.writeByte('{');
    var written = false;
    for (story.program.globals, state.globals, state.global_defaults) |global, value, default| {
        if (value == .null or values_equal(story, value, default)) continue;
        if (written) try writer.writeByte(',');
        written = true;
        try write_json_string(writer, story.program.strings.get(global.name));
        try writer.writeByte(':');
        try write_value(story, writer, value);
    }
    try writer.writeByte('}');
}

/// ink's RuntimeObjectsEqual (for saving only non-default globals): same type, then the
/// same value; strings by text, lists by their items (unlike `Value.identical`, which
/// compares references and float bits).
fn values_equal(story: *Story, a: Value, b: Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .string => |text| std.mem.eql(u8, text_of(story, text), text_of(story, b.string)),
        .list => |list| list_items_equal(story, list, b.list),
        .null => true,
        .integer => |number| number == b.integer,
        .float => |number| number == b.float,
        .bool => |flag| flag == b.bool,
        .divert_target => |target| target == b.divert_target,
        .variable_pointer => |pointer| pointer.name == b.variable_pointer.name and
            pointer.context == b.variable_pointer.context,
        .tag => |text| std.mem.eql(u8, text_of(story, text), text_of(story, b.tag)),
    };
}

fn list_items_equal(
    story: *Story,
    a: value_module.ListReference,
    b: value_module.ListReference,
) bool {
    assert(story.state.lists.check_reference(a) and story.state.lists.check_reference(b));
    const items_a = story.state.lists.view(a).items;
    const items_b = story.state.lists.view(b).items;
    if (items_a.len != items_b.len) return false;
    for (items_a) |item| {
        if (std.mem.indexOfScalar(ListItemIndex, items_b, item) == null) return false;
    }
    return true;
}

const Counts = enum { visits, turns };

fn write_counts(story: *Story, writer: *Writer, counts: Counts) Writer.Error!void {
    const containers = story.program.containers;
    try writer.writeByte('{');
    var written = false;
    var position: u32 = 0;
    while (position < containers.len) : (position += 1) {
        const info = containers.get(position);
        if (info.count_slot == container_module.no_count_slot) continue;
        const number: i64 = switch (counts) {
            .visits => story.state.visit_counts[info.count_slot],
            .turns => story.state.turn_indices[info.count_slot],
        };
        const unset = switch (counts) {
            .visits => number == 0,
            .turns => number == state_module.never_visited,
        };
        if (unset) continue;
        if (written) try writer.writeByte(',');
        written = true;
        try write_json_string(writer, story.program.strings.get(info.path));
        try writer.print(":{d}", .{number});
    }
    try writer.writeByte('}');
}

/// ink's Json.WriteRuntimeObject for a value.
fn write_value(story: *Story, writer: *Writer, value: Value) Writer.Error!void {
    switch (value) {
        .null => try writer.writeAll("\"void\""),
        .integer => |number| try writer.print("{d}", .{number}),
        .float => |number| try dotnet_float.write_json(writer, number),
        .bool => |flag| try writer.writeAll(if (flag) "true" else "false"),
        .string => |reference| {
            const text = text_of(story, reference);
            if (std.mem.eql(u8, text, "\n")) return writer.writeAll("\"\\n\"");
            try writer.writeAll("\"^");
            try write_escaped(writer, text);
            try writer.writeByte('"');
        },
        .divert_target => |target| {
            try writer.writeAll("{\"^->\":");
            try write_json_string(writer, path_of(story, target));
            try writer.writeByte('}');
        },
        .variable_pointer => |pointer| {
            try writer.writeAll("{\"^var\":");
            try write_json_string(writer, story.program.strings.get(pointer.name));
            try writer.print(",\"ci\":{d}}}", .{pointer.context});
        },
        .list => |list| try write_list(story, writer, list),
        .tag => |reference| {
            try writer.writeAll("{\"#\":");
            try write_json_string(writer, text_of(story, reference));
            try writer.writeByte('}');
        },
    }
}

/// ink's WriteInkList: `origin.item: value` in iteration order, and an empty list's origins.
fn write_list(story: *Story, writer: *Writer, list: value_module.ListReference) Writer.Error!void {
    assert(story.state.lists.check_reference(list));
    const view = story.state.lists.view(list);
    const program = story.program;
    try writer.writeAll("{\"list\":{");
    for (view.items, 0..) |item, position| {
        if (position > 0) try writer.writeByte(',');
        const info = program.list_items[item.to_int()];
        try write_json_string(writer, program.strings.get(info.full_name));
        try writer.print(":{d}", .{info.value});
    }
    try writer.writeByte('}');
    if (view.items.len == 0 and view.origins.len > 0) {
        try writer.writeAll(",\"origins\":[");
        for (view.origins, 0..) |origin, position| {
            if (position > 0) try writer.writeByte(',');
            try write_json_string(
                writer,
                program.strings.get(program.list_origins[origin.to_int()].name),
            );
        }
        try writer.writeByte(']');
    }
    try writer.writeByte('}');
}

fn write_json_string(writer: *Writer, text: []const u8) Writer.Error!void {
    assert(text.len < 1 << 30);
    try writer.writeByte('"');
    try write_escaped(writer, text);
    try writer.writeByte('"');
}

/// SimpleJson's WriteEscapedString: `\` and `"` escaped, `\n` and `\t` as escapes, other
/// control characters dropped.
fn write_escaped(writer: *Writer, text: []const u8) Writer.Error!void {
    for (text) |character| {
        switch (character) {
            '\n' => try writer.writeAll("\\n"),
            '\t' => try writer.writeAll("\\t"),
            '\\', '"' => {
                try writer.writeByte('\\');
                try writer.writeByte(character);
            },
            else => if (character >= ' ') try writer.writeByte(character),
        }
    }
}
