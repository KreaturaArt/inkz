//! The newline lookahead: ink's StateSnapshot, RestoreStateSnapshot and
//! DiscardSnapshot without copying the whole state.
//!
//! Taking a snapshot copies the used prefixes of the live-flow buffers into the lookahead
//! buffers and records the scalars: heap tops, queue and diagnostic lengths, the turn index
//! and the random state. The shared arrays (globals, visit counts, turn indices) are copied
//! on write, a chunk of `chunk_slots` slots at a time: while a snapshot is active, writes go
//! through `set_global`, `set_visit_count` and `set_turn_index`, which copy the slot's chunk
//! before its first write (ink's StatePatch). Restoring copies the buffers and the written
//! chunks back and truncates the heap.
//!
//! Sliding compaction keeps the heap's order, so the heap tops stay object boundaries when
//! compaction relocates them (`State.compact`).

const std = @import("std");
const assert = std.debug.assert;
const profile = @import("../core/profile.zig");
const state_module = @import("state.zig");
const value_module = @import("value.zig");
const index = @import("../core/index.zig");
const State = state_module.State;
const Value = value_module.Value;
const flow_buffers = state_module.flow_buffers;

/// Slots per copied chunk of a shared array: the visit counts and turn indices of a chunk
/// are copied together, since they share slots.
pub const chunk_slots = @import("../core/limits.zig").lookahead_chunk_slots;

/// What a snapshot remembers besides the buffer copies.
pub const Snapshot = struct {
    active: bool = false,
    /// The copied length of each flow buffer, in `flow_buffers` order.
    counts: [flow_buffers.len]u32 = @splat(0),
    thread_counter: u32 = 0,
    strings_top: u32 = 0,
    lists_top: u32 = 0,
    observer_events: u32 = 0,
    errors: u32 = 0,
    warnings: u32 = 0,
    diagnostic_bytes: u32 = 0,
    diagnostics_dropped: u32 = 0,
    turn_index: i32 = -1,
    story_seed: i32 = 0,
    previous_random: i32 = 0,
    did_safe_exit: bool = false,
};

pub fn active(state: *const State) bool {
    assert(state.snapshot.active or state.snapshot.strings_top == 0);
    return state.snapshot.active;
}

/// ink's StateSnapshot.
pub fn take(state: *State) void {
    const profile_zone = profile.begin(.lookahead_take);
    defer profile_zone.end();
    assert(!state.snapshot.active);
    assert(copied_count(state) == 0);
    var counts: [flow_buffers.len]u32 = undefined;
    inline for (flow_buffers, &counts) |buffer, *count| {
        const into = @field(state.lookahead, @tagName(buffer));
        const stack = state.flow_stack(buffer);
        assert(into.len == stack.buffer.len);
        @memcpy(into[0..stack.count], stack.slice());
        count.* = stack.count;
    }
    state.snapshot = .{
        .active = true,
        .counts = counts,
        .thread_counter = state.call_stack.thread_counter,
        .strings_top = state.strings.used,
        .lists_top = state.lists.used,
        .observer_events = state.observer_events.count,
        .errors = state.errors.count,
        .warnings = state.warnings.count,
        .diagnostic_bytes = state.diagnostic_bytes_used,
        .diagnostics_dropped = state.diagnostics_dropped,
        .turn_index = state.turn_index,
        .story_seed = state.story_seed,
        .previous_random = state.previous_random,
        .did_safe_exit = state.did_safe_exit,
    };
    assert(active(state));
}

/// ink's RestoreStateSnapshot: the state as it was at `take`, except that heap objects made
/// since then are gone.
pub fn restore(state: *State) void {
    const profile_zone = profile.begin(.lookahead_restore);
    defer profile_zone.end();
    assert(active(state));
    const snapshot = state.snapshot;
    const copy = state.lookahead.prefix(&snapshot.counts);
    inline for (flow_buffers) |buffer| {
        const stack = state.flow_stack(buffer);
        stack.clear();
        // The copy came from this stack, so it fits.
        stack.push_slice(@field(copy, @tagName(buffer))) catch unreachable;
    }
    copy_back(state);
    state.call_stack.thread_counter = snapshot.thread_counter;
    state.strings.truncate(snapshot.strings_top);
    state.lists.truncate(snapshot.lists_top);
    state.observer_events.count = snapshot.observer_events;
    state.errors.count = snapshot.errors;
    state.warnings.count = snapshot.warnings;
    state.diagnostic_bytes_used = snapshot.diagnostic_bytes;
    state.diagnostics_dropped = snapshot.diagnostics_dropped;
    state.turn_index = snapshot.turn_index;
    state.story_seed = snapshot.story_seed;
    state.previous_random = snapshot.previous_random;
    state.did_safe_exit = snapshot.did_safe_exit;
    state.snapshot = .{};
    assert(!active(state));
}

/// ink's DiscardSnapshot: keeps every change made since `take`.
pub fn discard(state: *State) void {
    assert(active(state));
    @memset(state.lookahead_copied, 0);
    state.snapshot = .{};
    assert(!active(state));
}

/// Into the snapshot's copy (`out`), or from it (`back`).
const Direction = enum { out, back };

/// The globals' chunks come first in `lookahead_copied`, then the counts' chunks.
fn global_chunks(state: *const State) u32 {
    const count: u32 = @intCast(state.globals.len);
    const chunks = (count + chunk_slots - 1) / chunk_slots; // rounded up
    assert(chunks * chunk_slots >= count);
    return chunks;
}

fn is_copied(state: *const State, chunk: u32) bool {
    assert(chunk / 32 < state.lookahead_copied.len);
    return state.lookahead_copied[chunk / 32] & (@as(u32, 1) << @intCast(chunk % 32)) != 0;
}

/// Copies a chunk out before its first write since `take`.
fn copy_on_write(state: *State, chunk: u32) void {
    assert(active(state));
    if (is_copied(state, chunk)) return;
    state.lookahead_copied[chunk / 32] |= @as(u32, 1) << @intCast(chunk % 32);
    copy_chunk(state, chunk, .out);
    assert(is_copied(state, chunk));
}

/// Copies every copied chunk back and clears the bitset.
fn copy_back(state: *State) void {
    for (state.lookahead_copied, 0..) |*word, at| {
        var bits = word.*;
        while (bits != 0) : (bits &= bits - 1) {
            copy_chunk(state, @intCast(at * 32 + @ctz(bits)), .back);
        }
        word.* = 0;
    }
    assert(copied_count(state) == 0);
}

fn copy_chunk(state: *State, chunk: u32, direction: Direction) void {
    const globals = global_chunks(state);
    if (chunk < globals) {
        const range = slots(chunk, state.globals.len);
        const live = state.globals[range.first..range.end];
        copy_slots(Value, live, state.lookahead_globals[range.first..], direction);
    } else {
        const range = slots(chunk - globals, state.visit_counts.len);
        const counts = state.visit_counts[range.first..range.end];
        copy_slots(u32, counts, state.lookahead_visit_counts[range.first..], direction);
        const turns = state.turn_indices[range.first..range.end];
        copy_slots(i32, turns, state.lookahead_turn_indices[range.first..], direction);
    }
}

/// The slots of the `chunk`th chunk of an array of `len` slots.
fn slots(chunk: u32, len: usize) struct { first: u32, end: u32 } {
    const first = chunk * chunk_slots;
    assert(first < len);
    const end: u32 = @intCast(@min(first + chunk_slots, len));
    assert(end > first);
    return .{ .first = first, .end = end };
}

fn copy_slots(comptime T: type, live: []T, saved: []T, direction: Direction) void {
    assert(live.len <= chunk_slots and live.len <= saved.len);
    switch (direction) {
        .out => @memcpy(saved[0..live.len], live),
        .back => @memcpy(live, saved[0..live.len]),
    }
}

fn copied_count(state: *const State) u32 {
    var count: u32 = 0;
    for (state.lookahead_copied) |word| count += @popCount(word);
    assert(count <= state.lookahead_copied.len * 32);
    return count;
}

pub fn set_global(state: *State, slot: index.GlobalSlot, value: Value) void {
    const at = slot.to_int();
    assert(at < state.globals.len);
    if (active(state)) copy_on_write(state, at / chunk_slots);
    state.globals[at] = value;
}

pub fn set_visit_count(state: *State, slot: u32, count: u32) void {
    assert(slot < state.visit_counts.len);
    if (active(state)) copy_on_write(state, global_chunks(state) + slot / chunk_slots);
    state.visit_counts[slot] = count;
}

pub fn set_turn_index(state: *State, slot: u32, turn: i32) void {
    assert(slot < state.turn_indices.len);
    if (active(state)) copy_on_write(state, global_chunks(state) + slot / chunk_slots);
    state.turn_indices[slot] = turn;
}

pub const Fault = enum {
    ok,
    inactive_with_copies,
    count_exceeds_buffer,
    heap_top_past_used,
};

/// Checks the snapshot's lengths against its buffers and the heap, and that no chunk is
/// copied without a snapshot.
pub fn check(state: *const State) Fault {
    const snapshot = &state.snapshot;
    if (!snapshot.active) return if (copied_count(state) == 0) .ok else .inactive_with_copies;
    inline for (flow_buffers, snapshot.counts) |buffer, count| {
        if (count > @field(state.lookahead, @tagName(buffer)).len) return .count_exceeds_buffer;
    }
    const pairs = [_][2]u32{
        .{ snapshot.errors, state.errors.capacity() },
        .{ snapshot.warnings, state.warnings.capacity() },
        .{ snapshot.observer_events, state.observer_events.capacity() },
    };
    for (pairs) |pair| if (pair[0] > pair[1]) return .count_exceeds_buffer;
    if (snapshot.strings_top > state.strings.used) return .heap_top_past_used;
    if (snapshot.lists_top > state.lists.used) return .heap_top_past_used;
    return .ok;
}

/// The heap references held by the snapshot's copies: compaction roots.
pub fn visit(state: *State, visitor: anytype) void {
    assert(@typeInfo(@TypeOf(visitor)) == .pointer);
    if (!active(state)) return;
    state_module.visit_flow(state.lookahead.prefix(&state.snapshot.counts), visitor);
    for (0..global_chunks(state)) |chunk| {
        if (!is_copied(state, @intCast(chunk))) continue;
        const range = slots(@intCast(chunk), state.globals.len);
        for (state.lookahead_globals[range.first..range.end]) |*value| {
            state_module.visit_value(value, visitor);
        }
    }
}

const Program = @import("../core/program.zig").Program;
const ProgramBuilder = @import("../core/program_builder.zig").ProgramBuilder;
const Limits = @import("../core/limits.zig").Limits;

fn test_state(gpa: std.mem.Allocator, program: *Program, state: *State, limits: Limits) !void {
    var builder = try ProgramBuilder.init(gpa);
    defer builder.deinit();
    _ = try builder.begin_container(.{ .flags = .{ .visits_counted = true } });
    try builder.add(.global_get, try builder.global("score"));
    try builder.add(.done, {});
    try builder.end_container();
    program.* = try builder.finish();
    try state.init(gpa, program, limits);
    assert(state.globals.len == 1 and state.visit_counts.len == 1);
}

fn store_text(state: *State, text: []const u8) value_module.StringReference {
    assert(text.len < 1 << 16);
    assert(state.strings.used <= state.strings.bytes.len);
    const reference = state.strings.try_allocate(@intCast(text.len)).?;
    @memcpy(state.strings.get(reference), text);
    assert(state.strings.get(reference).len == text.len);
    return reference;
}

/// Changes every part of the state a lookahead can change.
fn change_everything(state: *State) !void {
    assert(active(state));
    try state.evaluation.push(.{ .string = store_text(state, "pushed") });
    try state.call_stack.push(.function, state.evaluation.count, state.output.items.count);
    const line = store_text(state, "more text\n");
    try state.output.push_text(&state.strings, state.call_stack.current_frames(), line, 0, 10);
    set_global(state, .from_int(0), .{ .string = store_text(state, "changed") });
    set_global(state, .from_int(0), .{ .integer = 2 });
    set_visit_count(state, 0, 5);
    set_turn_index(state, 0, 3);
    _ = try state.lists.store(&.{.from_int(1)}, &.{});
    try state.observer_events.push(.from_int(0));
    state.add_diagnostic(.@"error", .null, "Story error.", .{});
    state.turn_index += 1;
    state.previous_random = 99;
    state.verify();
}

test "take then restore leaves the state bit-identical" {
    // Ink's RestoreStateSnapshot: hash a state with content, take, change
    // every part a lookahead can change, restore, compare hashes and the heap tops.
    const gpa = std.testing.allocator;
    var program: Program = undefined;
    var state: State = undefined;
    try test_state(gpa, &program, &state, .{});
    defer program.deinit(gpa);
    defer state.deinit(gpa);
    const line = store_text(&state, "hello\n");
    try state.output.push_text(&state.strings, state.call_stack.current_frames(), line, 0, 6);
    set_global(&state, .from_int(0), .{ .string = store_text(&state, "kept") });
    set_visit_count(&state, 0, 1);
    const before = state.hash();
    const strings_used = state.strings.used;
    take(&state);
    try std.testing.expect(state.hash() != before); // the active flag counts
    try change_everything(&state);
    restore(&state);
    try std.testing.expectEqual(before, state.hash());
    try std.testing.expectEqual(strings_used, state.strings.used);
    try std.testing.expectEqual(@as(u32, 0), state.lists.used);
    try std.testing.expectEqualStrings("kept", state.strings.get(state.globals[0].string));
    try std.testing.expect(!state.has_error()); // errors from a discarded lookahead go too
    state.verify();
}

test "discard keeps the lookahead's changes" {
    // Ink's DiscardSnapshot applies the patch: take, change, discard.
    const gpa = std.testing.allocator;
    var program: Program = undefined;
    var state: State = undefined;
    try test_state(gpa, &program, &state, .{});
    defer program.deinit(gpa);
    defer state.deinit(gpa);
    take(&state);
    try change_everything(&state);
    const changed = state.hash();
    discard(&state);
    try std.testing.expect(state.hash() != changed); // only the active flag differs
    try std.testing.expectEqual(@as(u32, 5), state.visit_counts[0]);
    try std.testing.expectEqual(@as(i32, 3), state.turn_indices[0]);
    try std.testing.expectEqual(@as(u32, 2), state.call_stack.depth());
    take(&state);
    restore(&state);
    try std.testing.expectEqual(@as(i32, 2), state.globals[0].integer);
}

test "the heap tops follow a compaction during lookahead" {
    // Compaction relocates the snapshot's heap marks: garbage below the mark, live strings on
    // both sides, compact, then restore.
    const gpa = std.testing.allocator;
    var program: Program = undefined;
    var state: State = undefined;
    try test_state(gpa, &program, &state, .{});
    defer program.deinit(gpa);
    defer state.deinit(gpa);
    _ = store_text(&state, "garbage before the snapshot");
    set_global(&state, .from_int(0), .{ .string = store_text(&state, "live") });
    _ = try state.lists.store(&.{.from_int(1)}, &.{});
    try state.evaluation.push(.{ .list = try state.lists.store(&.{.from_int(2)}, &.{}) });
    take(&state);
    try state.evaluation.push(.{ .string = store_text(&state, "made in lookahead") });
    _ = store_text(&state, "garbage in lookahead");
    set_global(&state, .from_int(0), .{ .integer = 1 });
    state.compact();
    // "live" (12 bytes with its header) is all that stays below the mark; the old global
    // value is kept alive by the snapshot's copy of the globals.
    try std.testing.expectEqual(@as(u32, 12), state.snapshot.strings_top);
    try std.testing.expectEqual(@as(u32, 4), state.snapshot.lists_top);
    try std.testing.expectEqual(@as(u32, 12 + 28), state.strings.used);
    state.verify();
    restore(&state);
    try std.testing.expectEqual(@as(u32, 12), state.strings.used);
    try std.testing.expectEqualStrings("live", state.strings.get(state.globals[0].string));
    try std.testing.expectEqual(@as(u32, 4), state.lists.used);
    state.verify();
}

test "a variable changed in a lookahead is restored, however often it was written" {
    // Ink's RestoreStateSnapshot for the shared arrays: 70 globals (two chunks) and a visit
    // count and turn index, written thousands of times during a lookahead (a story's `~ x++`
    // loop before the line ends). Each written chunk is copied once, restore brings back the
    // values from `take`, and after discard the last writes stay.
    const gpa = std.testing.allocator;
    var builder = try ProgramBuilder.init(gpa);
    defer builder.deinit();
    _ = try builder.begin_container(.{ .flags = .{ .visits_counted = true } });
    for (0..70) |position| {
        var name: [8]u8 = undefined;
        _ = try builder.global(try std.fmt.bufPrint(&name, "g{d}", .{position}));
    }
    try builder.add(.done, {});
    try builder.end_container();
    var program = try builder.finish();
    defer program.deinit(gpa);
    var state: State = undefined;
    try state.init(gpa, &program, .{});
    defer state.deinit(gpa);
    for (state.globals, 0..) |*global, position| global.* = .{ .integer = @intCast(position) };
    set_visit_count(&state, 0, 2);
    set_turn_index(&state, 0, 1);
    take(&state);
    for (0..5000) |round| {
        set_global(&state, .from_int(69), .{ .integer = @intCast(round) });
        set_visit_count(&state, 0, state.visit_counts[0] + 1);
        set_turn_index(&state, 0, @intCast(round));
    }
    try std.testing.expectEqual(@as(u32, 2), copied_count(&state));
    set_global(&state, .from_int(3), .{ .string = store_text(&state, "lookahead") });
    try std.testing.expectEqual(@as(u32, 3), copied_count(&state));
    try std.testing.expectEqual(Fault.ok, check(&state));
    restore(&state);
    for (state.globals, 0..) |global, position| {
        try std.testing.expectEqual(@as(i32, @intCast(position)), global.integer);
    }
    try std.testing.expectEqual(@as(u32, 2), state.visit_counts[0]);
    try std.testing.expectEqual(@as(i32, 1), state.turn_indices[0]);
    try std.testing.expectEqual(@as(u32, 0), copied_count(&state));
    take(&state);
    set_global(&state, .from_int(0), .{ .integer = 8 });
    set_global(&state, .from_int(0), .{ .integer = 9 });
    discard(&state);
    try std.testing.expectEqual(@as(i32, 9), state.globals[0].integer);
    try std.testing.expectEqual(@as(u32, 0), copied_count(&state));
    state.verify();
}
