//! Flows, as ink's StoryState flows: each flow has its own call stack,
//! output and choices; globals, counts, the evaluation stack and the random state are shared.
//!
//! Every flow owns a full set of buffers in `State.flow_storage`, one slot per flow record.
//! The live stacks (`State.call_stack`, `output`, `choices`) view the current flow's slot;
//! switching stores their counts in the outgoing flow's record and points them at the
//! target's slot, copying nothing. Flows that aren't current are compaction roots.

const std = @import("std");
const assert = std.debug.assert;
const Program = @import("../core/program.zig").Program;
const state_module = @import("state.zig");
const State = state_module.State;
const FlowRecord = state_module.FlowRecord;
const FlowBuffer = state_module.FlowBuffer;
const FlowElement = state_module.FlowElement;
const owned_buffers = state_module.owned_buffers;

pub const default_name = "DEFAULT_FLOW";

pub const Error = error{ FlowLimit, FlowNameTooLong, CannotRemoveDefaultFlow };

fn record_name(record: *const FlowRecord) []const u8 {
    assert(record.name_length <= state_module.flow_name_bytes_max);
    const name = record.name[0..record.name_length];
    assert(name.len == record.name_length);
    return name;
}

/// Flow `flow`'s slot of buffer `buffer`, at full capacity.
fn slot(state: *const State, flow: u32, comptime buffer: FlowBuffer) []FlowElement(buffer) {
    comptime assert(buffer != .evaluation);
    assert(flow < state.flows.len);
    const storage = @field(state.flow_storage, @tagName(buffer));
    const capacity = storage.len / state.flows.len;
    assert(capacity * state.flows.len == storage.len);
    return storage[flow * capacity ..][0..capacity];
}

/// Makes the default flow current and alone, its stacks on slot 0; called by State.reset,
/// which then clears them.
pub fn reset(state: *State) void {
    assert(state.flows.len > 0);
    for (state.flows) |*record| record.in_use = false;
    claim(state, 0, default_name);
    attach(state, 0);
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
    const existing = find(state, name);
    const target = existing orelse try create(state, name);
    assert(target != state.current_flow);
    select(state, target);
    if (existing == null) {
        state.call_stack.fresh(.start_of(Program.root));
        state.output.clear();
        state.choices.clear();
    }
    assert(state.current_flow == target);
}

/// Stores the live stacks' counts in the current flow's record and points them at flow
/// `target`'s slot with its counts. The stacks keep their peaks: one high-water mark for
/// all flows, as every slot has the same capacity.
pub fn select(state: *State, target: u32) void {
    assert(state.flows[target].in_use);
    const current = &state.flows[state.current_flow];
    inline for (owned_buffers, &current.counts) |buffer, *count| {
        count.* = state.flow_stack(buffer).count;
    }
    current.thread_counter = state.call_stack.thread_counter;
    current.indexed_count = state.choices.indexed_count;
    attach(state, target);
}

/// Points the live stacks at flow `target`'s slot, with the counts its record keeps.
fn attach(state: *State, target: u32) void {
    const record = &state.flows[target];
    assert(record.in_use);
    inline for (owned_buffers, record.counts) |buffer, count| {
        const stack = state.flow_stack(buffer);
        stack.buffer = slot(state, target, buffer);
        assert(count <= stack.buffer.len);
        stack.count = count;
    }
    state.call_stack.thread_counter = record.thread_counter;
    state.choices.indexed_count = record.indexed_count;
    state.current_flow = target;
}

fn create(state: *State, name: []const u8) Error!u32 {
    assert(state.flows[0].in_use);
    for (state.flows, 0..) |*record, position| {
        if (record.in_use) continue;
        claim(state, @intCast(position), name);
        return @intCast(position);
    }
    return error.FlowLimit;
}

fn claim(state: *State, position: u32, name: []const u8) void {
    assert(name.len <= state_module.flow_name_bytes_max);
    const record = &state.flows[position];
    assert(!record.in_use);
    record.* = .{
        .counts = @splat(0),
        .thread_counter = 0,
        .indexed_count = 0,
        .name = undefined,
        .name_length = @intCast(name.len),
        .in_use = true,
    };
    @memcpy(record.name[0..name.len], name);
    var in_use: u32 = 0;
    for (state.flows) |*flow| in_use += @intFromBool(flow.in_use);
    state.peaks.flows = @max(state.peaks.flows, in_use);
}

/// For loading a save: the record of flow `name`, created if needed (the default flow is
/// always record 0).
pub fn record_for(state: *State, name: []const u8) Error!u32 {
    if (name.len == 0 or name.len > state_module.flow_name_bytes_max) return error.FlowNameTooLong;
    const record = find(state, name) orelse try create(state, name);
    assert(state.flows[record].in_use);
    return record;
}

/// The used part of flow `flow`'s buffers, which isn't current. Its evaluation stack is
/// empty: flows share it.
pub fn view(state: *const State, flow: u32) state_module.FlowBuffers {
    const record = &state.flows[flow];
    assert(record.in_use and flow != state.current_flow);
    var buffers: state_module.FlowBuffers = undefined;
    buffers.evaluation = &.{};
    inline for (owned_buffers, record.counts) |buffer, count| {
        @field(buffers, @tagName(buffer)) = slot(state, flow, buffer)[0..count];
    }
    assert(buffers.threads.len > 0);
    return buffers;
}

/// ink's RemoveFlow: the default flow can't be removed; removing the current one switches
/// to the default first.
pub fn remove_flow(state: *State, name: []const u8) Error!void {
    if (std.mem.eql(u8, name, default_name)) return error.CannotRemoveDefaultFlow;
    const target = find(state, name) orelse return;
    assert(target != 0);
    if (target == state.current_flow) {
        assert(!state.snapshot.active);
        select(state, 0);
    }
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
    live_slot,
    counts_out_of_range,
    no_threads,
    name_too_long,
};

/// Checks the flow directory: the default flow is record 0 and in use, the live stacks view
/// the current flow's slot, and the other flows' counts fit their slots, with a thread each.
pub fn check(state: *const State) Fault {
    assert(state.flows.len > 0);
    const default = &state.flows[0];
    if (!default.in_use) return .default_flow;
    if (!std.mem.eql(u8, default.name[0..default.name_length], default_name)) return .default_flow;
    if (state.current_flow >= state.flows.len) return .current_flow;
    if (!state.flows[state.current_flow].in_use) return .current_flow;
    inline for (owned_buffers) |buffer| {
        const live = state.flow_stack(buffer).buffer;
        if (live.ptr != slot(state, state.current_flow, buffer).ptr) return .live_slot;
    }
    for (state.flows, 0..) |*record, position| {
        if (!record.in_use) continue;
        if (record.name_length > state_module.flow_name_bytes_max) return .name_too_long;
        if (position == state.current_flow) continue;
        inline for (owned_buffers, record.counts) |buffer, count| {
            if (count > state.flow_stack(buffer).capacity()) return .counts_out_of_range;
        }
        if (record.counts[@backingInt(FlowBuffer.threads) - 1] == 0) return .no_threads;
    }
    return .ok;
}

/// Visits the heap references of every flow but the current one, for compaction.
pub fn visit_others(state: *State, visitor: anytype) void {
    assert(state.flows.len > 0);
    for (state.flows, 0..) |*record, position| {
        if (!record.in_use or position == state.current_flow) continue;
        state_module.visit_flow(view(state, @intCast(position)), visitor);
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
    try state.init(gpa, program, .{ .flows_max = 3 });
    assert(state.flows.len == 3);
}

test "flows keep their own call stack and output, and new flows start at the root" {
    // Ink's TestMultiFlowBasics shape: change the default flow, switch to a
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

test "a switch moves the live stacks to the target's own slot and copies nothing" {
    // Each flow owns its buffers: the live stacks view a different slot per
    // flow, the same one again on the way back, and the peaks span all flows.
    const gpa = std.testing.allocator;
    var program: Program = undefined;
    var state: State = undefined;
    try test_state(gpa, &program, &state);
    defer program.deinit(gpa);
    defer state.deinit(gpa);
    const default_frames = state.call_stack.frames.buffer.ptr;
    try state.call_stack.push(.function, 0, 0);
    try state.call_stack.push(.function, 0, 0);
    try switch_flow(&state, "blue");
    try std.testing.expect(state.call_stack.frames.buffer.ptr != default_frames);
    try std.testing.expectEqual(@as(u32, 3), state.call_stack.frames.peak);
    const default_counts = state.flows[0].counts;
    try std.testing.expectEqual(@as(u32, 3), default_counts[@backingInt(FlowBuffer.frames) - 1]);
    try switch_flow(&state, default_name);
    try std.testing.expectEqual(default_frames, state.call_stack.frames.buffer.ptr);
    try std.testing.expectEqual(@as(u32, 3), state.call_stack.depth());
    try std.testing.expectEqual(Fault.ok, check(&state));
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

test "removing flows frees their records, and the limits return their errors" {
    // Bounds: switch between flows many times; remove the current one, then
    // another; check the flow and name limits.
    const gpa = std.testing.allocator;
    var program: Program = undefined;
    var state: State = undefined;
    try test_state(gpa, &program, &state);
    defer program.deinit(gpa);
    defer state.deinit(gpa);
    for (0..200) |round| {
        try switch_flow(&state, if (round % 2 == 0) "red" else "blue");
    }
    var sink: NameSink = .{};
    try alive_flow_names(&state, &sink);
    try std.testing.expectEqual(@as(u32, 2), sink.count);
    try std.testing.expectEqualStrings("blue", current_name(&state));
    try state.call_stack.push(.tunnel, 0, 0);
    try remove_flow(&state, "blue");
    try std.testing.expectEqualStrings(default_name, current_name(&state));
    try std.testing.expectEqual(@as(u32, 1), state.call_stack.depth());
    try std.testing.expect(find(&state, "blue") == null);
    try remove_flow(&state, "red");
    try std.testing.expect(find(&state, "red") == null);
    try std.testing.expectEqual(Fault.ok, check(&state));
    try std.testing.expectError(error.CannotRemoveDefaultFlow, remove_flow(&state, default_name));
    try switch_flow(&state, "a");
    try switch_flow(&state, "b");
    try std.testing.expectError(error.FlowLimit, switch_flow(&state, "c"));
    try std.testing.expectEqualStrings("b", current_name(&state));
    const long_name: [state_module.flow_name_bytes_max + 1]u8 = @splat('x');
    try std.testing.expectError(error.FlowNameTooLong, switch_flow(&state, &long_name));
}
