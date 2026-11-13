//! State.check against seeded corruptions, and heap compaction through State's root
//! visitor, one root kind at a time.

const std = @import("std");
const assert = std.debug.assert;
const Program = @import("../core/program.zig").Program;
const ProgramBuilder = @import("../core/program_builder.zig").ProgramBuilder;
const state_module = @import("state.zig");
const flows = @import("flows.zig");
const lookahead = @import("lookahead.zig");
const value_module = @import("value.zig");
const call_stack_module = @import("call_stack.zig");
const choices_module = @import("choices.zig");
const State = state_module.State;
const Value = value_module.Value;
const StringReference = value_module.StringReference;
const Pointer = call_stack_module.Pointer;

const Fixture = struct {
    program: Program,
    state: State,

    fn setup(fixture: *Fixture, gpa: std.mem.Allocator) !void {
        var builder = try ProgramBuilder.init(gpa);
        defer builder.deinit();
        _ = try builder.begin_container(.{ .flags = .{ .visits_counted = true } });
        try builder.add(.global_get, try builder.global("score"));
        try builder.add(.done, {});
        try builder.end_container();
        fixture.program = try builder.finish();
        try fixture.state.init(gpa, &fixture.program, .{});
        assert(fixture.state.globals.len == 1);
        assert(fixture.state.check() == .ok);
    }

    fn teardown(fixture: *Fixture, gpa: std.mem.Allocator) void {
        assert(fixture.state.memory.len > 0);
        fixture.state.deinit(gpa);
        fixture.program.deinit(gpa);
        fixture.* = undefined;
    }
};

const Corruption = enum {
    frame_range,
    dangling_string,
    dangling_list,
    temps_outside_frame,
    snapshot_range,
    parking_directory,
    parking_shape,
    lookahead_log,
};

fn corrupt(state: *State, corruption: Corruption) !State.Fault {
    assert(state.check() == .ok);
    assert(state.call_stack.depth() == 1);
    const choice: choices_module.Choice = .{
        .text = .none,
        .target = .start_of(Program.root),
        .source = .start_of(Program.root),
        .original_thread = 0,
        .thread_counter = 0,
        .tags_first = 0,
        .snapshot = 7,
        .tags_count = 0,
        .invisible_default = false,
    };
    switch (corruption) {
        .frame_range => state.call_stack.threads.buffer[0].frame_count = 5,
        .dangling_string => try state.evaluation.push(.{ .string = .heap(64) }),
        .dangling_list => try state.evaluation.push(.{ .list = @fromBackingInt(40) }),
        .temps_outside_frame => state.call_stack.frames.buffer[0].temps_count = 3,
        .snapshot_range => try state.choices.records.push(choice),
        .parking_directory => {
            try flows.switch_flow(state, "other");
            state.flows[0].parked_words += 1;
        },
        .parking_shape => {
            try flows.switch_flow(state, "other");
            state.parking[0] = 1000; // the parked frame count
        },
        .lookahead_log => state.snapshot.patch_count = 1,
    }
    return switch (corruption) {
        .frame_range, .temps_outside_frame => .call_stack,
        .dangling_string => .string_reference,
        .dangling_list => .list_reference,
        .snapshot_range => .choices,
        .parking_directory, .parking_shape => .flows,
        .lookahead_log => .lookahead,
    };
}

test "check reports each seeded corruption" {
    // One fresh state per corruption; check names the broken part.
    const gpa = std.testing.allocator;
    for (std.enums.values(Corruption)) |corruption| {
        var fixture: Fixture = undefined;
        try fixture.setup(gpa);
        defer fixture.teardown(gpa);
        const expected = try corrupt(&fixture.state, corruption);
        try std.testing.expectEqual(expected, fixture.state.check());
    }
}

fn store_text(state: *State, text: []const u8) StringReference {
    assert(text.len < 1 << 16);
    assert(state.strings.used <= state.strings.bytes.len);
    const reference = state.strings.try_allocate(@intCast(text.len)).?;
    @memcpy(state.strings.get(reference), text);
    assert(reference.is_heap());
    return reference;
}

/// A live string after a dead one, so compaction must move it.
fn live_after_garbage(state: *State, text: []const u8) StringReference {
    assert(text.len > 0);
    _ = store_text(state, "garbage garbage");
    const reference = store_text(state, text);
    assert(reference.heap_offset() > 0);
    return reference;
}

fn expect_text(state: *State, reference: StringReference, text: []const u8) !void {
    assert(text.len > 0);
    assert(state.strings.used > 0);
    try std.testing.expect(reference.is_heap());
    try std.testing.expectEqualStrings(text, state.strings.get(reference));
}

test "compaction keeps every root kind" {
    // Carried; each kind of root that holds heap references survives compaction
    // through State.visit. Per kind, a live string after garbage; compact; read back.
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.setup(gpa);
    defer fixture.teardown(gpa);
    const state = &fixture.state;
    // Default flow: temps, output, a choice with a tag and a snapshot holding the temp.
    const temp_name: @import("../core/index.zig").StringId = .from_int(1);
    const temp_value: Value = .{ .string = live_after_garbage(state, "temp") };
    try state.call_stack.temp_set(temp_name, temp_value, true, -1);
    const line = live_after_garbage(state, "parked line");
    try state.output.push_text(&state.strings, state.call_stack.current_frames(), line, 0, 11);
    const choice: choices_module.Choice = .{
        .text = live_after_garbage(state, "choice"),
        .target = .start_of(Program.root),
        .source = .start_of(Program.root),
        .original_thread = 0,
        .thread_counter = 0,
        .tags_first = 0,
        .snapshot = 0,
        .tags_count = 0,
        .invisible_default = false,
    };
    try state.choices.add(&state.call_stack, choice, &.{live_after_garbage(state, "tag")});
    // Park it, then fill the new flow and the shared roots, and take a lookahead.
    try flows.switch_flow(state, "other");
    state.global_defaults[0] = .{ .string = live_after_garbage(state, "default") };
    try lookahead.set_global(state, .from_int(0), .{ .string = live_after_garbage(state, "old") });
    const live_line = live_after_garbage(state, "live line");
    try state.output.push_text(&state.strings, state.call_stack.current_frames(), live_line, 0, 9);
    try state.observer_events.push(.from_int(0));
    lookahead.take(state);
    try state.evaluation.push(.{ .string = live_after_garbage(state, "evaluation") });
    try lookahead.set_global(state, .from_int(0), .{ .string = live_after_garbage(state, "new") });
    const used_before = state.strings.used;
    state.compact(&.{});
    try std.testing.expect(state.strings.used < used_before);
    state.verify();
    try expect_text(state, state.evaluation.peek().?.string, "evaluation");
    try expect_text(state, state.globals[0].string, "new");
    try expect_text(state, state.global_defaults[0].string, "default");
    try expect_text(state, state.output.items.slice()[0].string, "live line");
    try expect_text(state, state.lookahead.items[0].string, "live line");
    try std.testing.expectEqual(@as(u32, 1), state.observer_events.count);
    lookahead.restore(state); // the undo log's "old" was a root too
    try expect_text(state, state.globals[0].string, "old");
    try flows.switch_flow(state, flows.default_name);
    try expect_text(state, state.call_stack.temp_get(temp_name, -1).?.string, "temp");
    try expect_text(state, state.output.items.slice()[0].string, "parked line");
    const kept = state.choices.get(0);
    try expect_text(state, kept.text, "choice");
    try expect_text(state, state.choices.tags.slice()[kept.tags_first], "tag");
    try expect_text(state, state.choices.temps.slice()[0].value.string, "temp");
    state.verify();
}
