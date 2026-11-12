//! The newline lookahead (plan §4.6, P4.9): ink's StateSnapshot, RestoreStateSnapshot and
//! DiscardSnapshot without copying the whole state.
//!
//! Taking a snapshot copies the used prefixes of the live-flow buffers into the lookahead
//! buffers and records the scalars: heap tops, queue and diagnostic lengths, the turn index
//! and the random state. Shared arrays (globals, visit counts, turn indices) are not copied;
//! while a snapshot is active, writes to them go through `set_global`, `set_visit_count` and
//! `set_turn_index`, which log the previous value (ink's StatePatch, as an undo log).
//! Restoring copies the buffers back, undoes the log newest first and truncates the heap.
//!
//! Sliding compaction keeps the heap's order, so the heap tops stay object boundaries when
//! compaction relocates them (`State.compact`).

const std = @import("std");
const assert = std.debug.assert;
const state_module = @import("state.zig");
const value_module = @import("value.zig");
const index = @import("../core/index.zig");
const State = state_module.State;
const PatchEntry = state_module.PatchEntry;
const Value = value_module.Value;

pub const Error = error{LookaheadLogLimit};

/// What a snapshot remembers besides the buffer copies.
pub const Snapshot = struct {
    active: bool = false,
    evaluation: u32 = 0,
    frames: u32 = 0,
    threads: u32 = 0,
    temps: u32 = 0,
    items: u32 = 0,
    marks: u32 = 0,
    choices: u32 = 0,
    tags: u32 = 0,
    snapshots: u32 = 0,
    snapshot_frames: u32 = 0,
    snapshot_temps: u32 = 0,
    thread_counter: u32 = 0,
    strings_top: u32 = 0,
    lists_top: u32 = 0,
    observer_events: u32 = 0,
    errors: u32 = 0,
    warnings: u32 = 0,
    diagnostics_dropped: u32 = 0,
    patch_count: u32 = 0,
    turn_index: i32 = -1,
    story_seed: i32 = 0,
    previous_random: i32 = 0,
};

/// A PatchEntry's target: which shared array, and the slot in it.
const Kind = enum(u2) { global, visit_count, turn_index };

fn target_of(kind: Kind, slot: u32) u32 {
    assert(slot < 1 << 30);
    const target = (@as(u32, @backingInt(kind)) << 30) | slot;
    assert(target >> 30 == @backingInt(kind));
    return target;
}

fn kind_of(target: u32) Kind {
    const kind: Kind = @fromBackingInt(@intCast(target >> 30));
    assert(target_of(kind, slot_of(target)) == target);
    return kind;
}

fn slot_of(target: u32) u32 {
    const slot = target & ((1 << 30) - 1);
    assert(slot < 1 << 30);
    return slot;
}

pub fn active(state: *const State) bool {
    assert(state.snapshot.patch_count <= state.patch.len);
    assert(state.snapshot.active or state.snapshot.patch_count == 0);
    return state.snapshot.active;
}

/// ink's StateSnapshot.
pub fn take(state: *State) void {
    assert(!state.snapshot.active);
    const into = &state.lookahead;
    state.snapshot = .{
        .active = true,
        .evaluation = save(into.evaluation, state.evaluation),
        .frames = save(into.frames, state.call_stack.frames),
        .threads = save(into.threads, state.call_stack.threads),
        .temps = save(into.temps, state.call_stack.temps),
        .items = save(into.items, state.output.items),
        .marks = save(into.marks, state.output.string_marks),
        .choices = save(into.choices, state.choices.records),
        .tags = save(into.tags, state.choices.tags),
        .snapshots = save(into.snapshots, state.choices.snapshots),
        .snapshot_frames = save(into.snapshot_frames, state.choices.frames),
        .snapshot_temps = save(into.snapshot_temps, state.choices.temps),
        .thread_counter = state.call_stack.thread_counter,
        .strings_top = state.strings.used,
        .lists_top = state.lists.used,
        .observer_events = state.observer_events.count,
        .errors = state.errors.count,
        .warnings = state.warnings.count,
        .diagnostics_dropped = state.diagnostics_dropped,
        .turn_index = state.turn_index,
        .story_seed = state.story_seed,
        .previous_random = state.previous_random,
    };
    assert(active(state));
}

fn save(into: anytype, stack: anytype) u32 {
    assert(stack.count <= into.len);
    assert(into.len == stack.buffer.len);
    @memcpy(into[0..stack.count], stack.slice());
    return stack.count;
}

fn load(stack: anytype, from: anytype, count: u32) void {
    assert(count <= from.len);
    assert(from.len == stack.buffer.len);
    stack.clear();
    // The copy came from a stack of the same capacity.
    stack.push_slice(from[0..count]) catch unreachable;
    assert(stack.count == count);
}

/// ink's RestoreStateSnapshot: the state as it was at `take`, except that heap objects made
/// since then are gone.
pub fn restore(state: *State) void {
    assert(active(state));
    const snapshot = state.snapshot;
    const from = &state.lookahead;
    load(&state.evaluation, from.evaluation, snapshot.evaluation);
    load(&state.call_stack.frames, from.frames, snapshot.frames);
    load(&state.call_stack.threads, from.threads, snapshot.threads);
    load(&state.call_stack.temps, from.temps, snapshot.temps);
    load(&state.output.items, from.items, snapshot.items);
    load(&state.output.string_marks, from.marks, snapshot.marks);
    load(&state.choices.records, from.choices, snapshot.choices);
    load(&state.choices.tags, from.tags, snapshot.tags);
    load(&state.choices.snapshots, from.snapshots, snapshot.snapshots);
    load(&state.choices.frames, from.snapshot_frames, snapshot.snapshot_frames);
    load(&state.choices.temps, from.snapshot_temps, snapshot.snapshot_temps);
    state.call_stack.thread_counter = snapshot.thread_counter;
    undo(state);
    state.strings.truncate(snapshot.strings_top);
    state.lists.truncate(snapshot.lists_top);
    state.observer_events.count = snapshot.observer_events;
    state.errors.count = snapshot.errors;
    state.warnings.count = snapshot.warnings;
    state.diagnostics_dropped = snapshot.diagnostics_dropped;
    state.turn_index = snapshot.turn_index;
    state.story_seed = snapshot.story_seed;
    state.previous_random = snapshot.previous_random;
    state.snapshot = .{};
    assert(!active(state));
}

fn undo(state: *State) void {
    assert(state.snapshot.patch_count <= state.patch.len);
    var position = state.snapshot.patch_count;
    while (position > 0) {
        position -= 1;
        const entry = state.patch[position];
        const slot = slot_of(entry.target);
        switch (kind_of(entry.target)) {
            .global => state.globals[slot] = entry.old,
            .visit_count => state.visit_counts[slot] = @bitCast(entry.old.integer),
            .turn_index => state.turn_indices[slot] = entry.old.integer,
        }
    }
    assert(position == 0);
    state.snapshot.patch_count = 0;
}

/// ink's DiscardSnapshot: keeps every change made since `take`.
pub fn discard(state: *State) void {
    assert(active(state));
    state.snapshot = .{};
    assert(!active(state));
    assert(state.snapshot.patch_count == 0);
}

fn log(state: *State, kind: Kind, slot: u32, old: Value) Error!void {
    assert(active(state));
    const count = state.snapshot.patch_count;
    if (count == state.patch.len) return error.LookaheadLogLimit;
    state.patch[count] = .{ .target = target_of(kind, slot), .old = old };
    state.snapshot.patch_count = count + 1;
    assert(state.snapshot.patch_count <= state.patch.len);
}

pub fn set_global(state: *State, slot: index.GlobalSlot, value: Value) Error!void {
    const at = slot.to_int();
    assert(at < state.globals.len);
    if (active(state)) try log(state, .global, at, state.globals[at]);
    state.globals[at] = value;
    assert(std.meta.activeTag(state.globals[at]) == std.meta.activeTag(value));
}

pub fn set_visit_count(state: *State, slot: u32, count: u32) Error!void {
    assert(slot < state.visit_counts.len);
    const old: Value = .{ .integer = @bitCast(state.visit_counts[slot]) };
    if (active(state)) try log(state, .visit_count, slot, old);
    state.visit_counts[slot] = count;
    assert(state.visit_counts.len == state.turn_indices.len);
}

pub fn set_turn_index(state: *State, slot: u32, turn: i32) Error!void {
    assert(slot < state.turn_indices.len);
    const old: Value = .{ .integer = state.turn_indices[slot] };
    if (active(state)) try log(state, .turn_index, slot, old);
    state.turn_indices[slot] = turn;
    assert(state.visit_counts.len == state.turn_indices.len);
}

pub const Fault = enum { ok, inactive_with_log, count_exceeds_buffer, heap_top_past_used };

/// Checks the snapshot's lengths against its buffers and the heap.
pub fn check(state: *const State) Fault {
    const snapshot = &state.snapshot;
    assert(state.patch.len > 0);
    if (!snapshot.active) {
        return if (snapshot.patch_count == 0) .ok else .inactive_with_log;
    }
    const copy = &state.lookahead;
    const pairs = [_][2]usize{
        .{ snapshot.evaluation, copy.evaluation.len },
        .{ snapshot.frames, copy.frames.len },
        .{ snapshot.threads, copy.threads.len },
        .{ snapshot.temps, copy.temps.len },
        .{ snapshot.items, copy.items.len },
        .{ snapshot.marks, copy.marks.len },
        .{ snapshot.choices, copy.choices.len },
        .{ snapshot.tags, copy.tags.len },
        .{ snapshot.snapshots, copy.snapshots.len },
        .{ snapshot.patch_count, state.patch.len },
        .{ snapshot.snapshot_frames, copy.snapshot_frames.len },
        .{ snapshot.snapshot_temps, copy.snapshot_temps.len },
        .{ snapshot.errors, state.errors.buffer.len },
        .{ snapshot.warnings, state.warnings.buffer.len },
        .{ snapshot.observer_events, state.observer_events.buffer.len },
    };
    assert(pairs.len == 15);
    for (pairs) |pair| if (pair[0] > pair[1]) return .count_exceeds_buffer;
    if (snapshot.strings_top > state.strings.used) return .heap_top_past_used;
    if (snapshot.lists_top > state.lists.used) return .heap_top_past_used;
    return .ok;
}

/// The heap references held by the snapshot copies and by logged globals: compaction roots.
pub fn visit(state: *State, visitor: anytype) void {
    assert(@typeInfo(@TypeOf(visitor)) == .pointer);
    if (!active(state)) return;
    const snapshot = &state.snapshot;
    const copy = &state.lookahead;
    assert(snapshot.evaluation <= copy.evaluation.len and snapshot.temps <= copy.temps.len);
    state_module.visit_values(copy.evaluation[0..snapshot.evaluation], visitor);
    state_module.visit_temps(copy.temps[0..snapshot.temps], visitor);
    for (copy.items[0..snapshot.items]) |*item| {
        if (item.kind == .text or item.kind == .tag) visitor.string(&item.string);
    }
    for (copy.choices[0..snapshot.choices]) |*choice| visitor.string(&choice.text);
    for (copy.tags[0..snapshot.tags]) |*tag| visitor.string(tag);
    state_module.visit_temps(copy.snapshot_temps[0..snapshot.snapshot_temps], visitor);
    for (state.patch[0..snapshot.patch_count]) |*entry| {
        if (kind_of(entry.target) != .global) continue;
        state_module.visit_values((&entry.old)[0..1], visitor);
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
    assert(std.mem.eql(u8, state.strings.get(reference), text));
    return reference;
}

/// Changes every part of the state a lookahead can change.
fn change_everything(state: *State) !void {
    assert(active(state));
    try state.evaluation.push(.{ .string = store_text(state, "pushed") });
    try state.call_stack.push(.function, state.evaluation.count, state.output.items.count);
    const line = store_text(state, "more text\n");
    try state.output.push_text(&state.strings, state.call_stack.current_frames(), line, 0, 10);
    try set_global(state, .from_int(0), .{ .string = store_text(state, "changed") });
    try set_global(state, .from_int(0), .{ .integer = 2 });
    try set_visit_count(state, 0, 5);
    try set_turn_index(state, 0, 3);
    _ = try state.lists.store(&.{.from_int(1)}, &.{});
    try state.observer_events.push(.from_int(0));
    const diagnostic: state_module.Diagnostic =
        .{ .argument = line, .number = 1, .code = .story_error, .severity = .@"error" };
    state.add_diagnostic(diagnostic);
    state.turn_index += 1;
    state.previous_random = 99;
    state.verify();
}

test "take then restore leaves the state bit-identical" {
    // Goal: P4.9; ink's RestoreStateSnapshot. Method: hash a state with content, take, change
    // every part a lookahead can change, restore, compare hashes and the heap tops.
    const gpa = std.testing.allocator;
    var program: Program = undefined;
    var state: State = undefined;
    try test_state(gpa, &program, &state, .{});
    defer program.deinit(gpa);
    defer state.deinit(gpa);
    const line = store_text(&state, "hello\n");
    try state.output.push_text(&state.strings, state.call_stack.current_frames(), line, 0, 6);
    try set_global(&state, .from_int(0), .{ .string = store_text(&state, "kept") });
    try set_visit_count(&state, 0, 1);
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
    // Goal: P4.9; ink's DiscardSnapshot applies the patch. Method: take, change, discard.
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
    // Goal: P4.9; compaction relocates the snapshot's heap marks (plan §4.6, point 5).
    // Method: garbage below the mark, live strings on both sides, compact, then restore.
    const gpa = std.testing.allocator;
    var program: Program = undefined;
    var state: State = undefined;
    try test_state(gpa, &program, &state, .{});
    defer program.deinit(gpa);
    defer state.deinit(gpa);
    _ = store_text(&state, "garbage before the snapshot");
    try set_global(&state, .from_int(0), .{ .string = store_text(&state, "live") });
    _ = try state.lists.store(&.{.from_int(1)}, &.{});
    try state.evaluation.push(.{ .list = try state.lists.store(&.{.from_int(2)}, &.{}) });
    take(&state);
    try state.evaluation.push(.{ .string = store_text(&state, "made in lookahead") });
    _ = store_text(&state, "garbage in lookahead");
    try set_global(&state, .from_int(0), .{ .integer = 1 });
    state.compact();
    // "live" (12 bytes with its header) is all that stays below the mark; the old global
    // value is kept alive by the undo log.
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

test "the undo log returns its error when full" {
    // Goal: P4.9 bound. Method: a two-entry log and three writes during a lookahead.
    const gpa = std.testing.allocator;
    var program: Program = undefined;
    var state: State = undefined;
    try test_state(gpa, &program, &state, .{ .patch_entries_max = 2 });
    defer program.deinit(gpa);
    defer state.deinit(gpa);
    try set_global(&state, .from_int(0), .{ .integer = 1 });
    try set_global(&state, .from_int(0), .{ .integer = 2 });
    try set_global(&state, .from_int(0), .{ .integer = 3 }); // no log outside a lookahead
    take(&state);
    try set_global(&state, .from_int(0), .{ .integer = 4 });
    try set_visit_count(&state, 0, 1);
    try std.testing.expectError(error.LookaheadLogLimit, set_turn_index(&state, 0, 1));
    restore(&state);
    try std.testing.expectEqual(@as(i32, 3), state.globals[0].integer);
    try std.testing.expectEqual(@as(u32, 0), state.visit_counts[0]);
}
