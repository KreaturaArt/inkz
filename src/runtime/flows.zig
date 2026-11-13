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
const State = state_module.State;
const FlowRecord = state_module.FlowRecord;
const FlowBuffer = state_module.FlowBuffer;
const FlowElement = state_module.FlowElement;
const parked_buffers = state_module.parked_buffers;

pub const default_name = "DEFAULT_FLOW";

pub const Error = error{ FlowLimit, FlowNameTooLong, FlowParkingLimit, CannotRemoveDefaultFlow };

/// What starts a parked flow: the length of each parked buffer, in `parked_buffers` order,
/// then the call stack's thread counter.
const Header = extern struct {
    counts: [parked_buffers.len]u32,
    thread_counter: u32,

    fn count(header: *const Header, comptime buffer: FlowBuffer) u32 {
        comptime assert(buffer != .evaluation);
        return header.counts[@backingInt(buffer) - 1];
    }
};

const header_words = @sizeOf(Header) / 4;

comptime {
    assert(header_words == parked_buffers.len + 1);
    assert(@backingInt(parked_buffers[0]) == 1);
}

/// The words a parked flow with these buffer lengths takes, its header included.
pub fn parked_size(counts: [parked_buffers.len]u32) u64 {
    var words: u64 = header_words;
    inline for (parked_buffers, counts) |buffer, count| {
        words += @as(u64, count) * (@sizeOf(FlowElement(buffer)) / 4);
    }
    assert(words >= header_words);
    return words;
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
        var in_use: u32 = 0;
        for (state.flows) |*flow| in_use += @intFromBool(flow.in_use);
        state.peaks.flows = @max(state.peaks.flows, in_use);
        return @intCast(position);
    }
    return error.FlowLimit;
}

/// For loading a save: the record of flow `name`, created if needed (the default flow is
/// always record 0).
pub fn record_for(state: *State, name: []const u8) Error!u32 {
    if (name.len == 0 or name.len > state_module.flow_name_bytes_max) return error.FlowNameTooLong;
    const record = find(state, name) orelse try create(state, name);
    assert(state.flows[record].in_use);
    return record;
}

/// For loading a save: parks the live buffers as flow `record`'s content, leaving the live
/// buffers to be filled with the next flow.
pub fn park_live_into(state: *State, record: u32) Error!void {
    assert(record < state.flows.len and state.flows[record].in_use);
    assert(state.flows[record].parked_words == 0);
    const current = state.current_flow;
    state.current_flow = record;
    defer state.current_flow = current;
    try park_current(state);
}

/// The words in use in the parking region: parked flows are packed from the start.
pub fn parking_used(state: *const State) u32 {
    var used: u32 = 0;
    for (state.flows) |*record| {
        if (record.in_use) used = @max(used, record.parked_first + record.parked_words);
    }
    assert(used <= state.parking.len);
    return used;
}

/// Packs the current flow into the parking region.
fn park_current(state: *State) Error!void {
    const thread_counter = state.call_stack.thread_counter;
    var header: Header = .{ .counts = undefined, .thread_counter = thread_counter };
    inline for (parked_buffers, &header.counts) |buffer, *count| {
        count.* = state.flow_stack(buffer).count;
    }
    const at = parking_used(state);
    assert(state.flows[state.current_flow].parked_words == 0);
    var writer: Writer = .{ .words = state.parking, .at = at };
    try writer.put(Header, &.{header});
    inline for (parked_buffers) |buffer| {
        try writer.put(FlowElement(buffer), state.flow_stack(buffer).slice());
    }
    const record = &state.flows[state.current_flow];
    record.parked_first = at;
    record.parked_words = writer.at - at;
    state.peaks.parking_words = @max(state.peaks.parking_words, writer.at);
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

/// A parked flow's buffers, in place. Its evaluation stack is empty: flows share it.
pub const Parked = struct {
    buffers: state_module.FlowBuffers,
    thread_counter: u32,

    pub fn of(words: []u32) Parked {
        assert(words.len >= header_words);
        var reader: Reader = .{ .words = words };
        const header = reader.take(Header, 1)[0];
        var parked: Parked = .{ .buffers = undefined, .thread_counter = header.thread_counter };
        parked.buffers.evaluation = &.{};
        inline for (parked_buffers, header.counts) |buffer, count| {
            @field(parked.buffers, @tagName(buffer)) = reader.take(FlowElement(buffer), count);
        }
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

pub fn parked_words(state: *State, record: *const FlowRecord) []u32 {
    assert(record.in_use);
    assert(record.parked_first + record.parked_words <= state.parking.len);
    return state.parking[record.parked_first..][0..record.parked_words];
}

/// Copies flow `target` back into the live buffers and frees its parking.
fn unpark(state: *State, target: u32) void {
    const record = &state.flows[target];
    const parked = Parked.of(parked_words(state, record));
    inline for (parked_buffers) |buffer| {
        const stack = state.flow_stack(buffer);
        stack.clear();
        // The parked flow fit these buffers when it was live, so it fits again.
        stack.push_slice(@field(parked.buffers, @tagName(buffer))) catch unreachable;
    }
    state.call_stack.thread_counter = parked.thread_counter;
    release(state, target);
    assert(record.parked_words == 0);
    state.call_stack.verify();
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
    inline for (parked_buffers, header.counts) |buffer, count| {
        if (count > state.flow_stack(buffer).capacity()) return false;
    }
    if (header.count(.threads) == 0) return false;
    return parked_size(header.counts) == record.parked_words;
}

/// Visits the heap references of every parked flow, for compaction.
pub fn visit_parked(state: *State, visitor: anytype) void {
    assert(state.flows.len > 0);
    for (state.flows) |*record| {
        if (!record.in_use or record.parked_words == 0) continue;
        const parked = Parked.of(parked_words(state, record));
        assert(parked.buffers.threads.len > 0);
        state_module.visit_flow(parked.buffers, visitor);
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
