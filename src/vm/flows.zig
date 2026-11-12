//! Flows (plan §4.5, P4.8), as ink's StoryState flows: each flow has its own call stack,
//! output and choices; globals, counts, the evaluation stack and the random state are shared.
//!
//! Only the current flow lives in the state's live buffers. Switching packs the used part of
//! each live buffer into the parking region (words, behind a header of counts) and unpacks
//! the target flow, or starts it fresh at the root. Parked flows are compaction roots: their
//! heap references are visited in place. Removing a flow closes the gap in the region.

const std = @import("std");
const assert = std.debug.assert;
const Program = @import("../core/program.zig").Program;
const state_module = @import("state.zig");
const call_stack_module = @import("call_stack.zig");
const output_module = @import("output.zig");
const choices_module = @import("choices.zig");
const value_module = @import("value.zig");
const State = state_module.State;
const FlowRecord = state_module.FlowRecord;

pub const default_name = "DEFAULT_FLOW";

pub const Error = error{ FlowLimit, FlowNameTooLong, FlowParkingLimit, CannotRemoveDefaultFlow };

const header_words = 11;

/// The counts that start a parked flow, in the order its arrays follow. `extern` keeps the
/// field order, so the first ten words are the array lengths in order.
const Header = extern struct {
    frames: u32,
    threads: u32,
    temps: u32,
    items: u32,
    marks: u32,
    choices: u32,
    tags: u32,
    snapshots: u32,
    snapshot_frames: u32,
    snapshot_temps: u32,
    thread_counter: u32,
};

comptime {
    assert(@typeInfo(Header).@"struct".field_names.len == header_words);
}

fn words_of(comptime T: type, count: u32) u32 {
    comptime assert(@sizeOf(T) % 4 == 0);
    const words = count * (@sizeOf(T) / 4);
    assert(words >= count or @sizeOf(T) < 4);
    return words;
}

fn record_name(record: *const FlowRecord) []const u8 {
    assert(record.name_length <= state_module.flow_name_bytes_max);
    const name = record.name[0..record.name_length];
    assert(name.len == record.name_length);
    return name;
}

/// Makes the default flow current and alone; called by State.reset.
pub fn reset(state: *State) void {
    assert(state.flows.len > 0);
    for (state.flows) |*record| record.in_use = false;
    const record = &state.flows[0];
    record.* = .{
        .name = undefined,
        .parked_first = 0,
        .parked_words = 0,
        .thread_counter = 0,
        .name_length = default_name.len,
        .in_use = true,
    };
    @memcpy(record.name[0..default_name.len], default_name);
    state.current_flow = 0;
    assert(std.mem.eql(u8, current_name(state), default_name));
}

pub fn current_name(state: *const State) []const u8 {
    assert(state.current_flow < state.flows.len);
    assert(state.flows[0].in_use);
    const record = &state.flows[state.current_flow];
    assert(record.in_use);
    return record_name(record);
}

fn find(state: *const State, name: []const u8) ?u32 {
    assert(name.len > 0);
    assert(name.len <= state_module.flow_name_bytes_max);
    for (state.flows, 0..) |*record, position| {
        if (record.in_use and std.mem.eql(u8, record_name(record), name)) return @intCast(position);
    }
    return null;
}

/// ink's SwitchFlow: makes flow `name` current, creating it at the root if it's new.
pub fn switch_flow(state: *State, name: []const u8) Error!void {
    if (name.len > state_module.flow_name_bytes_max) return error.FlowNameTooLong;
    if (std.mem.eql(u8, name, current_name(state))) return;
    assert(!state.snapshot.active);
    const target = find(state, name) orelse try create(state, name);
    assert(target != state.current_flow);
    try park_current(state);
    state.current_flow = target;
    const record = &state.flows[target];
    if (record.parked_words == 0) {
        state.call_stack.reset(.start_of(Program.root));
        state.output.clear();
        state.choices.clear();
    } else {
        unpark(state, target);
    }
    assert(state.current_flow == target);
}

fn create(state: *State, name: []const u8) Error!u32 {
    assert(name.len <= state_module.flow_name_bytes_max);
    for (state.flows, 0..) |*record, position| {
        if (record.in_use) continue;
        record.* = .{
            .name = undefined,
            .parked_first = 0,
            .parked_words = 0,
            .thread_counter = 0,
            .name_length = @intCast(name.len),
            .in_use = true,
        };
        @memcpy(record.name[0..name.len], name);
        assert(position > 0);
        return @intCast(position);
    }
    return error.FlowLimit;
}

/// The words in use in the parking region: parked flows are packed from the start.
fn parking_used(state: *const State) u32 {
    var used: u32 = 0;
    for (state.flows) |*record| {
        if (record.in_use) used = @max(used, record.parked_first + record.parked_words);
    }
    assert(used <= state.parking.len);
    return used;
}

/// Packs the current flow into the parking region.
fn park_current(state: *State) Error!void {
    const header: Header = .{
        .frames = state.call_stack.frames.count,
        .threads = state.call_stack.threads.count,
        .temps = state.call_stack.temps.count,
        .items = state.output.items.count,
        .marks = state.output.string_marks.count,
        .choices = state.choices.records.count,
        .tags = state.choices.tags.count,
        .snapshots = state.choices.snapshots.count,
        .snapshot_frames = state.choices.frames.count,
        .snapshot_temps = state.choices.temps.count,
        .thread_counter = state.call_stack.thread_counter,
    };
    const at = parking_used(state);
    assert(state.flows[state.current_flow].parked_words == 0);
    var writer: Writer = .{ .words = state.parking, .at = at };
    try writer.put(Header, &.{header});
    try writer.put(call_stack_module.Frame, state.call_stack.frames.slice());
    try writer.put(call_stack_module.Thread, state.call_stack.threads.slice());
    try writer.put(call_stack_module.Temp, state.call_stack.temps.slice());
    try writer.put(output_module.Item, state.output.items.slice());
    try writer.put(u32, state.output.string_marks.slice());
    try writer.put(choices_module.Choice, state.choices.records.slice());
    try writer.put(value_module.StringReference, state.choices.tags.slice());
    try writer.put(choices_module.Snapshot, state.choices.snapshots.slice());
    try writer.put(call_stack_module.Frame, state.choices.frames.slice());
    try writer.put(call_stack_module.Temp, state.choices.temps.slice());
    const record = &state.flows[state.current_flow];
    record.parked_first = at;
    record.parked_words = writer.at - at;
    assert(record.parked_words >= header_words);
}

const Writer = struct {
    words: []u32,
    at: u32,

    fn put(writer: *Writer, comptime T: type, items: []const T) Error!void {
        const count = words_of(T, @intCast(items.len));
        if (count > writer.words.len - writer.at) return error.FlowParkingLimit;
        const source = std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(items));
        assert(source.len == count);
        @memcpy(writer.words[writer.at..][0..count], source);
        writer.at += count;
        assert(writer.at <= writer.words.len);
    }
};

/// A view of a parked flow's arrays, in place.
const Parked = struct {
    header: Header,
    frames: []call_stack_module.Frame,
    threads: []call_stack_module.Thread,
    temps: []call_stack_module.Temp,
    items: []output_module.Item,
    marks: []u32,
    choices: []choices_module.Choice,
    tags: []value_module.StringReference,
    snapshots: []choices_module.Snapshot,
    snapshot_frames: []call_stack_module.Frame,
    snapshot_temps: []call_stack_module.Temp,

    fn of(words: []u32) Parked {
        assert(words.len >= header_words);
        var reader: Reader = .{ .words = words };
        const header = reader.take(Header, 1)[0];
        const parked: Parked = .{
            .header = header,
            .frames = reader.take(call_stack_module.Frame, header.frames),
            .threads = reader.take(call_stack_module.Thread, header.threads),
            .temps = reader.take(call_stack_module.Temp, header.temps),
            .items = reader.take(output_module.Item, header.items),
            .marks = reader.take(u32, header.marks),
            .choices = reader.take(choices_module.Choice, header.choices),
            .tags = reader.take(value_module.StringReference, header.tags),
            .snapshots = reader.take(choices_module.Snapshot, header.snapshots),
            .snapshot_frames = reader.take(call_stack_module.Frame, header.snapshot_frames),
            .snapshot_temps = reader.take(call_stack_module.Temp, header.snapshot_temps),
        };
        assert(reader.at == words.len);
        return parked;
    }
};

const Reader = struct {
    words: []u32,
    at: u32 = 0,

    fn take(reader: *Reader, comptime T: type, count: u32) []T {
        const words = words_of(T, count);
        assert(reader.at + words <= reader.words.len);
        comptime assert(@alignOf(T) <= 4);
        const raw = reader.words[reader.at..][0..words];
        reader.at += words;
        return @alignCast(std.mem.bytesAsSlice(T, std.mem.sliceAsBytes(raw)));
    }
};

fn parked_words(state: *State, record: *const FlowRecord) []u32 {
    assert(record.in_use);
    assert(record.parked_first + record.parked_words <= state.parking.len);
    return state.parking[record.parked_first..][0..record.parked_words];
}

/// Copies flow `target` back into the live buffers and frees its parking.
fn unpark(state: *State, target: u32) void {
    const record = &state.flows[target];
    const parked = Parked.of(parked_words(state, record));
    replace(&state.call_stack.frames, parked.frames);
    replace(&state.call_stack.threads, parked.threads);
    replace(&state.call_stack.temps, parked.temps);
    state.call_stack.thread_counter = parked.header.thread_counter;
    replace(&state.output.items, parked.items);
    replace(&state.output.string_marks, parked.marks);
    replace(&state.choices.records, parked.choices);
    replace(&state.choices.tags, parked.tags);
    replace(&state.choices.snapshots, parked.snapshots);
    replace(&state.choices.frames, parked.snapshot_frames);
    replace(&state.choices.temps, parked.snapshot_temps);
    release(state, target);
    assert(record.parked_words == 0);
    state.call_stack.verify();
}

fn replace(stack: anytype, items: anytype) void {
    assert(@typeInfo(@TypeOf(stack)) == .pointer);
    // The parked flow fit these buffers when it was live, so it fits again.
    assert(items.len <= stack.buffer.len);
    stack.clear();
    stack.push_slice(items) catch unreachable;
    assert(stack.count == items.len);
}

/// Frees a flow's parked words and closes the gap so parked flows stay packed.
fn release(state: *State, target: u32) void {
    const record = &state.flows[target];
    const first = record.parked_first;
    const count = record.parked_words;
    const used = parking_used(state);
    assert(first + count <= used);
    const tail = state.parking[first + count .. used];
    std.mem.copyForwards(u32, state.parking[first .. used - count], tail);
    for (state.flows) |*other| {
        if (other.in_use and other.parked_words > 0 and other.parked_first > first) {
            other.parked_first -= count;
        }
    }
    record.parked_first = 0;
    record.parked_words = 0;
    assert(count >= header_words);
    assert(parking_used(state) == used - count);
}

/// ink's RemoveFlow: the default flow can't be removed; removing the current one switches
/// to the default first.
pub fn remove_flow(state: *State, name: []const u8) Error!void {
    if (std.mem.eql(u8, name, default_name)) return error.CannotRemoveDefaultFlow;
    if (std.mem.eql(u8, name, current_name(state))) try switch_flow(state, default_name);
    const target = find(state, name) orelse return;
    assert(target != 0 and target != state.current_flow);
    if (state.flows[target].parked_words > 0) release(state, target);
    state.flows[target].in_use = false;
    assert(find(state, name) == null);
}

/// Calls `sink.name(text)` for every flow except the default one (ink's aliveFlowNames).
pub fn alive_flow_names(state: *const State, sink: anytype) !void {
    assert(state.flows[0].in_use);
    for (state.flows) |*record| {
        if (!record.in_use) continue;
        const name = record_name(record);
        if (std.mem.eql(u8, name, default_name)) continue;
        assert(name.len > 0);
        try sink.name(name);
    }
}

pub const Fault = enum {
    ok,
    default_flow,
    current_flow,
    current_parked,
    parked_out_of_range,
    parked_overlap,
    parked_shape,
    name_too_long,
};

/// Checks the flow directory and the parking region: the default flow is record 0 and in
/// use, the current flow isn't parked, and parked regions are in range, disjoint, packed and
/// shaped as their headers say.
pub fn check(state: *const State) Fault {
    assert(state.flows.len > 0);
    const default = &state.flows[0];
    if (!default.in_use) return .default_flow;
    if (!std.mem.eql(u8, default.name[0..default.name_length], default_name)) return .default_flow;
    if (state.current_flow >= state.flows.len) return .current_flow;
    if (!state.flows[state.current_flow].in_use) return .current_flow;
    if (state.flows[state.current_flow].parked_words != 0) return .current_parked;
    var parked_total: u64 = 0;
    var parked_end: u64 = 0;
    for (state.flows) |*record| {
        if (!record.in_use) continue;
        if (record.name_length > state_module.flow_name_bytes_max) return .name_too_long;
        if (record.parked_words == 0) continue;
        const end = @as(u64, record.parked_first) + record.parked_words;
        if (end > state.parking.len) return .parked_out_of_range;
        if (!parked_shape_ok(state, record)) return .parked_shape;
        parked_total += record.parked_words;
        parked_end = @max(parked_end, end);
    }
    // Disjoint regions packed from the start cover exactly [0, end).
    if (parked_total != parked_end) return .parked_overlap;
    assert(parked_end <= state.parking.len);
    return .ok;
}

fn parked_shape_ok(state: *const State, record: *const FlowRecord) bool {
    assert(record.parked_words > 0);
    if (record.parked_words < header_words) return false;
    const words = state.parking[record.parked_first..][0..header_words];
    const header = std.mem.bytesToValue(Header, std.mem.sliceAsBytes(words));
    const capacities = [_]u32{
        state.call_stack.frames.capacity(),
        state.call_stack.threads.capacity(),
        state.call_stack.temps.capacity(),
        state.output.items.capacity(),
        state.output.string_marks.capacity(),
        state.choices.records.capacity(),
        state.choices.tags.capacity(),
        state.choices.snapshots.capacity(),
        state.choices.frames.capacity(),
        state.choices.temps.capacity(),
    };
    const counts = words[0..capacities.len];
    for (counts, capacities) |count, capacity| if (count > capacity) return false;
    assert(counts[1] == header.threads);
    if (header.threads == 0) return false;
    const expected = header_words + words_of(call_stack_module.Frame, header.frames) +
        words_of(call_stack_module.Thread, header.threads) +
        words_of(call_stack_module.Temp, header.temps) +
        words_of(output_module.Item, header.items) + header.marks +
        words_of(choices_module.Choice, header.choices) + header.tags +
        words_of(choices_module.Snapshot, header.snapshots) +
        words_of(call_stack_module.Frame, header.snapshot_frames) +
        words_of(call_stack_module.Temp, header.snapshot_temps);
    return expected == record.parked_words;
}

/// Visits the heap references of every parked flow, for compaction.
pub fn visit_parked(state: *State, visitor: anytype) void {
    assert(state.flows.len > 0);
    for (state.flows) |*record| {
        if (!record.in_use or record.parked_words == 0) continue;
        const parked = Parked.of(parked_words(state, record));
        assert(parked.threads.len > 0);
        for (parked.temps) |*temp| visit_value(&temp.value, visitor);
        for (parked.items) |*item| {
            if (item.kind == .text or item.kind == .tag) visitor.string(&item.string);
        }
        for (parked.choices) |*choice| visitor.string(&choice.text);
        for (parked.tags) |*tag| visitor.string(tag);
        for (parked.snapshot_temps) |*temp| visit_value(&temp.value, visitor);
    }
}

fn visit_value(value: *value_module.Value, visitor: anytype) void {
    assert(@sizeOf(value_module.Value) == 12);
    assert(@typeInfo(@TypeOf(visitor)) == .pointer);
    switch (value.*) {
        .string => |*reference| visitor.string(reference),
        .tag => |*reference| visitor.string(reference),
        .list => |*reference| visitor.list(reference),
        else => {},
    }
}

const ProgramBuilder = @import("../core/program_builder.zig").ProgramBuilder;

fn test_state(gpa: std.mem.Allocator, program: *Program, state: *State) !void {
    var builder = try ProgramBuilder.init(gpa);
    defer builder.deinit();
    _ = try builder.begin_container(.{});
    try builder.add(.done, {});
    try builder.end_container();
    program.* = try builder.finish();
    try state.init(gpa, program, .{ .flows_max = 3, .flow_parking_bytes_max = 4096 });
    assert(state.flows.len == 3);
}

test "flows keep their own call stack and output, and new flows start at the root" {
    // Goal: P4.8; ink's TestMultiFlowBasics shape. Method: change the default flow, switch to a
    // new flow (fresh), change it, switch back and forth.
    const gpa = std.testing.allocator;
    var program: Program = undefined;
    var state: State = undefined;
    try test_state(gpa, &program, &state);
    defer program.deinit(gpa);
    defer state.deinit(gpa);
    try state.call_stack.push(.tunnel, 0, 0);
    try switch_flow(&state, "blue");
    try std.testing.expectEqual(@as(u32, 1), state.call_stack.depth());
    try state.call_stack.push(.function, 0, 0);
    try state.call_stack.push(.function, 0, 0);
    try switch_flow(&state, default_name);
    try std.testing.expectEqual(@as(u32, 2), state.call_stack.depth());
    try switch_flow(&state, "blue");
    try std.testing.expectEqual(@as(u32, 3), state.call_stack.depth());
    try std.testing.expectEqualStrings("blue", current_name(&state));
    state.verify();
}

const NameSink = struct {
    count: u32 = 0,
    last: [8]u8 = undefined,

    pub fn name(sink: *NameSink, text: []const u8) !void {
        assert(text.len <= 8);
        assert(sink.count < 8);
        @memcpy(sink.last[0..text.len], text);
        sink.count += 1;
    }
};

test "removing flows frees their parking and switching stays bounded" {
    // Goal: P4.8 bounds. Method: switch between flows many times; remove one; check the
    // parking region stays packed, and that the limits return their errors.
    const gpa = std.testing.allocator;
    var program: Program = undefined;
    var state: State = undefined;
    try test_state(gpa, &program, &state);
    defer program.deinit(gpa);
    defer state.deinit(gpa);
    for (0..200) |round| {
        try switch_flow(&state, if (round % 2 == 0) "red" else "blue");
        try std.testing.expect(parking_used(&state) < 400);
    }
    var sink: NameSink = .{};
    try alive_flow_names(&state, &sink);
    try std.testing.expectEqual(@as(u32, 2), sink.count);
    try std.testing.expectEqualStrings("blue", current_name(&state));
    try remove_flow(&state, "blue");
    try std.testing.expectEqualStrings(default_name, current_name(&state));
    try std.testing.expect(parking_used(&state) > 0);
    try remove_flow(&state, "red");
    try std.testing.expectEqual(@as(u32, 0), parking_used(&state));
    try std.testing.expectError(error.CannotRemoveDefaultFlow, remove_flow(&state, default_name));
    try switch_flow(&state, "a");
    try switch_flow(&state, "b");
    try std.testing.expectError(error.FlowLimit, switch_flow(&state, "c"));
    const long_name: [state_module.flow_name_bytes_max + 1]u8 = @splat('x');
    try std.testing.expectError(error.FlowNameTooLong, switch_flow(&state, &long_name));
}
