//! Saving (plan §4.10, P6.1): ink's StoryState.ToJson, save format v10, streamed to a
//! writer with no allocation. The output is JSON-equivalent to C# ink's (D15): the same keys
//! and values; object key order may differ.

const std = @import("std");
const assert = std.debug.assert;
const profile = @import("../core/profile.zig");
const container_module = @import("../core/container.zig");
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
const Value = value_module.Value;
const Pointer = call_stack_module.Pointer;
const Frame = call_stack_module.Frame;
const Thread = call_stack_module.Thread;
const Temp = call_stack_module.Temp;
const Item = output_module.Item;
const Choice = choices_module.Choice;
const Writer = std.Io.Writer;

pub const save_version = 10;
pub const format_version = 21;

/// One flow's arrays, live or parked.
const FlowView = struct {
    frames: []const Frame,
    threads: []const Thread,
    temps: []const Temp,
    items: []const Item,
    choices: []const Choice,
    tags: []const value_module.StringReference,
    snapshots: []const choices_module.Snapshot,
    snapshot_frames: []const Frame,
    snapshot_temps: []const Temp,
    thread_counter: u32,
    indexed_count: u32,
};

fn live_view(story: *Story) FlowView {
    assert(story.state.memory.len > 0);
    const state = &story.state;
    assert(state.call_stack.threads.count > 0);
    return .{
        .frames = state.call_stack.frames.slice(),
        .threads = state.call_stack.threads.slice(),
        .temps = state.call_stack.temps.slice(),
        .items = state.output.items.slice(),
        .choices = state.choices.records.slice(),
        .tags = state.choices.tags.slice(),
        .snapshots = state.choices.snapshots.slice(),
        .snapshot_frames = state.choices.frames.slice(),
        .snapshot_temps = state.choices.temps.slice(),
        .thread_counter = state.call_stack.thread_counter,
        .indexed_count = state.choices.indexed_count,
    };
}

fn parked_view(story: *Story, record: *const state_module.FlowRecord) FlowView {
    assert(record.in_use and record.parked_words > 0);
    const parked = flows.Parked.of(flows.parked_words(&story.state, record));
    assert(parked.threads.len > 0);
    return .{
        .frames = parked.frames,
        .threads = parked.threads,
        .temps = parked.temps,
        .items = parked.items,
        .choices = parked.choices,
        .tags = parked.tags,
        .snapshots = parked.snapshots,
        .snapshot_frames = parked.snapshot_frames,
        .snapshot_temps = parked.snapshot_temps,
        .thread_counter = parked.header.thread_counter,
        .indexed_count = @intCast(parked.choices.len),
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
            parked_view(story, record);
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
    assert(view.choices.len <= story.state.choices.records.capacity());
    assert(view.threads.len > 0);
    try writer.writeAll("{\"callstack\":{\"threads\":[");
    for (view.threads, 0..) |thread, position| {
        if (position > 0) try writer.writeByte(',');
        const frames = view.frames[thread.frame_first..][0..thread.frame_count];
        try write_thread(
            story,
            writer,
            frames,
            view.temps,
            thread.counter,
            thread.previous_pointer,
        );
    }
    try writer.print("],\"threadCounter\":{d}}},\"outputStream\":[", .{view.thread_counter});
    for (view.items, 0..) |item, position| {
        if (position > 0) try writer.writeByte(',');
        try write_item(story, writer, item);
    }
    try writer.writeByte(']');
    try write_choice_threads(story, writer, view);
    try writer.writeAll(",\"currentChoices\":[");
    var visible: u32 = 0;
    for (view.choices, 0..) |choice, position| {
        if (position > 0) try writer.writeByte(',');
        const choice_index: u32 = if (position < view.indexed_count) visible else 0;
        if (!choice.invisible_default) visible += 1;
        try write_choice(story, writer, view, choice, choice_index);
    }
    try writer.writeAll("]}");
}

/// ink's choiceThreads: the stored thread of each choice whose thread isn't live.
fn write_choice_threads(story: *Story, writer: *Writer, view: FlowView) Writer.Error!void {
    assert(view.threads.len > 0);
    assert(view.snapshots.len <= story.state.choices.snapshots.capacity());
    var written = false;
    for (view.choices) |choice| {
        if (thread_is_live(view, choice.thread_counter)) continue;
        try writer.writeAll(if (written) "," else ",\"choiceThreads\":{");
        written = true;
        const snapshot = view.snapshots[choice.snapshot];
        const frames = view.snapshot_frames[snapshot.frames_first..][0..snapshot.frames_count];
        try writer.print("\"{d}\":", .{choice.thread_counter});
        try write_thread(
            story,
            writer,
            frames,
            view.snapshot_temps,
            choice.thread_counter,
            snapshot.previous_pointer,
        );
    }
    if (written) try writer.writeByte('}');
}

fn thread_is_live(view: FlowView, counter: u32) bool {
    assert(counter < std.math.maxInt(u32));
    assert(view.threads.len > 0);
    for (view.threads) |thread| {
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
    assert(story.state.memory.len > 0);
    assert(frames.len > 0);
    try writer.writeAll("{\"callstack\":[");
    for (frames, 0..) |frame, position| {
        if (position > 0) try writer.writeByte(',');
        try writer.writeByte('{');
        if (!frame.pointer.is_null()) {
            try writer.writeAll("\"cPath\":");
            try write_json_string(writer, story.path_of(frame.pointer.container));
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
    assert(pointer.container.to_int() < story.program.containers.len);
    assert(!pointer.is_null());
    const program = story.program;
    // ink's Pointer.Resolve gives the container itself for its own index and for an empty
    // container.
    const empty = program.content_count(pointer.container) == 0;
    if (pointer.index == Pointer.container_self or empty) {
        return write_json_string(writer, story.path_of(pointer.container));
    }
    if (pointer.index < program.content_count(pointer.container)) {
        if (program.container_at(pointer.container, pointer.index)) |child| {
            return write_json_string(writer, story.path_of(child));
        }
    }
    const path = story.path_of(pointer.container);
    if (path.len == 0) return writer.print("\"{d}\"", .{pointer.index});
    try writer.writeByte('"');
    try write_escaped(writer, path);
    try writer.print(".{d}\"", .{pointer.index});
}

fn write_item(story: *Story, writer: *Writer, item: Item) Writer.Error!void {
    assert(story.state.memory.len > 0);
    assert(@sizeOf(Item) == 12);
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
    choice_index: u32,
) Writer.Error!void {
    assert(story.state.memory.len > 0);
    assert(choice.tags_first + choice.tags_count <= view.tags.len);
    try writer.writeAll("{\"text\":");
    try write_json_string(writer, story.text_of(choice.text));
    try writer.print(",\"index\":{d},\"originalChoicePath\":", .{choice_index});
    try write_object_path(story, writer, choice.source);
    try writer.print(",\"originalThreadIndex\":{d},\"targetPath\":", .{choice.thread_counter});
    try write_target_path(story, writer, choice.target);
    if (choice.tags_count > 0) {
        try writer.writeAll(",\"tags\":[");
        for (view.tags[choice.tags_first..][0..choice.tags_count], 0..) |tag, position| {
            if (position > 0) try writer.writeByte(',');
            try write_json_string(writer, story.text_of(tag));
        }
        try writer.writeByte(']');
    }
    try writer.writeByte('}');
}

/// A choice target: a container's path when it targets its start, else the item's path.
fn write_target_path(story: *Story, writer: *Writer, target: Pointer) Writer.Error!void {
    assert(target.container.to_int() < story.program.containers.len);
    assert(!target.is_null());
    if (target.index == 0) return write_json_string(writer, story.path_of(target.container));
    try write_object_path(story, writer, target);
}

/// ink writes only globals that differ from their defaults.
fn write_variables(story: *Story, writer: *Writer) Writer.Error!void {
    assert(story.program.globals.len == story.state.globals.len);
    const state = &story.state;
    assert(state.globals.len == state.global_defaults.len);
    try writer.writeByte('{');
    var written = false;
    for (story.program.globals, state.globals, state.global_defaults) |global, value, default| {
        if (value == .null or story.values_equal(value, default)) continue;
        if (written) try writer.writeByte(',');
        written = true;
        try write_json_string(writer, story.program.strings.get(global.name));
        try writer.writeByte(':');
        try write_value(story, writer, value);
    }
    try writer.writeByte('}');
}

const Counts = enum { visits, turns };

fn write_counts(story: *Story, writer: *Writer, counts: Counts) Writer.Error!void {
    assert(@backingInt(counts) <= 1);
    const table = story.program.table();
    assert(story.state.visit_counts.len == story.state.turn_indices.len);
    try writer.writeByte('{');
    var written = false;
    var position: u32 = 0;
    while (position < table.count()) : (position += 1) {
        const info = table.get(.from_int(position));
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
    assert(story.state.memory.len > 0);
    assert(@sizeOf(Value) == 12);
    switch (value) {
        .null => try writer.writeAll("\"void\""),
        .integer => |number| try writer.print("{d}", .{number}),
        .float => |number| try write_float(writer, number),
        .bool => |flag| try writer.writeAll(if (flag) "true" else "false"),
        .string => |reference| {
            const text = story.text_of(reference);
            if (std.mem.eql(u8, text, "\n")) return writer.writeAll("\"\\n\"");
            try writer.writeAll("\"^");
            try write_escaped(writer, text);
            try writer.writeByte('"');
        },
        .divert_target => |target| {
            try writer.writeAll("{\"^->\":");
            try write_json_string(writer, story.path_of(target));
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
            try write_json_string(writer, story.text_of(reference));
            try writer.writeByte('}');
        },
    }
}

/// ink's WriteInkList: `origin.item: value` in iteration order, and an empty list's origins.
fn write_list(story: *Story, writer: *Writer, list: value_module.ListReference) Writer.Error!void {
    assert(story.state.lists.check_reference(list));
    const view = story.state.lists.view(list);
    const program = story.program;
    assert(view.items.len <= program.list_items.len);
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

/// SimpleJson's float: .NET's text, `.0` when it has no point or exponent, and ink's
/// stand-ins for infinities and NaN.
pub fn write_float(writer: *Writer, number: f32) Writer.Error!void {
    assert(@sizeOf(f32) == 4);
    assert(writer.end <= writer.buffer.len);
    if (std.math.isNan(number)) return writer.writeAll("0.0");
    if (std.math.isInf(number)) return writer.writeAll(if (number > 0) "3.4E+38" else "-3.4E+38");
    var buffer: [value_module.float_text_bytes_max]u8 = undefined;
    const text = value_module.format_float(number, &buffer);
    try writer.writeAll(text);
    const has_point = std.mem.indexOfAny(u8, text, ".E") != null;
    if (!has_point) try writer.writeAll(".0");
}

fn write_json_string(writer: *Writer, text: []const u8) Writer.Error!void {
    assert(writer.end <= writer.buffer.len);
    assert(text.len < 1 << 30);
    try writer.writeByte('"');
    try write_escaped(writer, text);
    try writer.writeByte('"');
}

/// SimpleJson's WriteEscapedString: `\` and `"` escaped, `\n` and `\t` as escapes, other
/// control characters dropped.
fn write_escaped(writer: *Writer, text: []const u8) Writer.Error!void {
    assert(writer.end <= writer.buffer.len);
    assert(text.len < 1 << 30);
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
