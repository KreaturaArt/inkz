//! The runtime state of one story (plan §4.5). Every buffer comes from one allocation of
//! exactly `Limits.bytes_total()` bytes, made in `init`; nothing allocates afterwards.
//!
//! The live flow (evaluation stack, call stack, output, choices) is what the lookahead
//! snapshot copies (P4.9) and what flows park (P4.8). Globals, counts, the heap, the random
//! state and the diagnostics are shared by every flow.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const index = @import("../core/index.zig");
const limits_module = @import("../core/limits.zig");
const fault = @import("../core/fault.zig");
const BoundedStack = @import("../core/bounded_stack.zig").BoundedStack;
const Program = @import("../core/program.zig").Program;
const value_module = @import("value.zig");
const heap = @import("heap.zig");
const lists_module = @import("lists.zig");
const call_stack_module = @import("call_stack.zig");
const output_module = @import("output.zig");
const choices_module = @import("choices.zig");
const flows = @import("flows.zig");
const lookahead_module = @import("lookahead.zig");
const Limits = limits_module.Limits;
const element_bytes = limits_module.element_bytes;
const Value = value_module.Value;
const StringReference = value_module.StringReference;
const ContainerIndex = index.ContainerIndex;
const GlobalSlot = index.GlobalSlot;
const Frame = call_stack_module.Frame;
const Thread = call_stack_module.Thread;
const Temp = call_stack_module.Temp;
const CallStack = call_stack_module.CallStack;
const Output = output_module.Output;
const Choices = choices_module.Choices;

/// A runtime error or warning, as ink's currentErrors and currentWarnings hold them.
pub const Diagnostic = struct {
    /// A string argument, such as a variable name, or a reference to nothing.
    argument: StringReference,
    number: i32,
    code: Code,
    severity: Severity,

    pub const Severity = enum(u8) { @"error", warning };
    /// Filled in by the VM's error handling (P5.10).
    pub const Code = enum(u16) { story_error, _ };
};

/// One undo record of the lookahead change log (P4.9): what a shared value was before.
pub const PatchEntry = struct {
    /// What changed; see lookahead.zig.
    target: u32,
    old: Value,
};

/// A variable observer registered by the host (P5.7, P6.3).
pub const Observer = struct {
    callback: ?*const anyopaque,
    context: ?*anyopaque,
    slot: GlobalSlot,
};

/// A flow's directory entry (P4.8). Flow names are stored inline.
pub const FlowRecord = struct {
    name: [flow_name_bytes_max]u8,
    parked_first: u32,
    parked_words: u32,
    thread_counter: u32,
    name_length: u8,
    in_use: bool,
};

pub const flow_name_bytes_max = 50;

comptime {
    assert(@sizeOf(Diagnostic) == element_bytes.diagnostic);
    assert(@sizeOf(PatchEntry) == element_bytes.patch_entry);
    assert(@sizeOf(Observer) == element_bytes.observer);
    assert(@sizeOf(FlowRecord) == element_bytes.flow);
    assert(@sizeOf(choices_module.Snapshot) == element_bytes.snapshot);
}

/// The buffers of one live flow: the live one, or its lookahead copy.
pub const FlowBuffers = struct {
    evaluation: []Value,
    frames: []Frame,
    threads: []Thread,
    temps: []Temp,
    items: []output_module.Item,
    marks: []u32,
    choices: []choices_module.Choice,
    tags: []StringReference,
    snapshots: []choices_module.Snapshot,
    snapshot_frames: []Frame,
    snapshot_temps: []Temp,
};

pub const State = struct {
    program: *const Program,
    limits: Limits,
    memory: []align(8) u8,

    // The live flow.
    evaluation: BoundedStack(Value),
    call_stack: CallStack,
    output: Output,
    choices: Choices,

    // Shared by all flows.
    globals: []Value,
    global_defaults: []Value,
    visit_counts: []u32,
    turn_indices: []i32,
    turn_index: i32 = -1,
    story_seed: i32 = 0,
    previous_random: i32 = 0,
    strings: heap.StringHeap,
    lists: lists_module.ListSlab,
    /// The current line's text and tags, assembled by `cont()`.
    line_bytes: []u8,
    observers: []Observer,
    observer_events: BoundedStack(GlobalSlot),
    errors: BoundedStack(Diagnostic),
    warnings: BoundedStack(Diagnostic),
    /// Scratch for the visit-counting walk (plan §4.6).
    ancestors: []ContainerIndex,

    // The lookahead snapshot (P4.9) and parked flows (P4.8).
    lookahead: FlowBuffers,
    patch: []PatchEntry,
    flows: []FlowRecord,
    parking: []u32,
    current_flow: u32 = 0,
    snapshot: lookahead_module.Snapshot = .{},

    pub const Fault = enum {
        ok,
        call_stack,
        output,
        choices,
        strings,
        evaluation,
        counts_length,
        string_reference,
    };

    pub fn shape_of(program: *const Program) Limits.ProgramShape {
        assert(program.globals.len < std.math.maxInt(u32));
        assert(program.containers.len > 0);
        return .{
            .count_slots = program.count_slots_count,
            .globals_count = @intCast(program.globals.len),
        };
    }

    /// Allocates every buffer in one block of `limits.bytes_total()` bytes.
    pub fn init(state: *State, gpa: Allocator, program: *const Program, limits: Limits) !void {
        limits.verify();
        if (limits.heap_bytes_max % 4 != 0 or limits.flow_parking_bytes_max % 4 != 0) {
            return error.InvalidLimits;
        }
        const total = limits.bytes_total(shape_of(program));
        const memory = try gpa.alignedAlloc(u8, .@"8", @intCast(total));
        var carver: Carver = .{ .memory = memory };
        state.* = carve(&carver, program, limits, memory);
        assert(carver.used == memory.len);
        state.reset();
    }

    pub fn deinit(state: *State, gpa: Allocator) void {
        assert(state.memory.len == state.limits.bytes_total(shape_of(state.program)));
        assert(state.memory.len > 0);
        gpa.free(state.memory);
        state.* = undefined;
    }

    /// The story's starting state: one thread at the root, empty output and choices, zeroed
    /// counts, globals undefined until the global declaration has run (P5).
    pub fn reset(state: *State) void {
        assert(state.memory.len > 0);
        state.evaluation.clear();
        state.call_stack.reset(.start_of(Program.root));
        state.output.clear();
        state.choices.clear();
        @memset(state.globals, .null);
        @memset(state.global_defaults, .null);
        @memset(state.visit_counts, 0);
        @memset(state.turn_indices, -1);
        state.turn_index = -1;
        state.previous_random = 0;
        state.strings.used = 0;
        state.lists.used = 0;
        state.observer_events.clear();
        state.errors.clear();
        state.warnings.clear();
        state.snapshot = .{};
        flows.reset(state);
        state.verify();
    }

    /// Calls `visitor.string` and `visitor.list` for every heap reference the state holds:
    /// the root set of heap compaction (plan §4.5).
    pub fn visit(state: *State, visitor: anytype) void {
        assert(@TypeOf(visitor) != void);
        assert(state.memory.len > 0);
        visit_values(state.evaluation.slice(), visitor);
        visit_values(state.globals, visitor);
        visit_values(state.global_defaults, visitor);
        visit_temps(state.call_stack.temps.slice(), visitor);
        for (state.output.items.slice()) |*item| {
            if (item.kind == .text or item.kind == .tag) visitor.string(&item.string);
        }
        for (state.choices.records.slice()) |*choice| visitor.string(&choice.text);
        for (state.choices.tags.slice()) |*tag| visitor.string(tag);
        visit_temps(state.choices.temps.slice(), visitor);
        for (state.errors.slice()) |*diagnostic| visitor.string(&diagnostic.argument);
        for (state.warnings.slice()) |*diagnostic| visitor.string(&diagnostic.argument);
        flows.visit_parked(state, visitor);
        lookahead_module.visit(state, visitor);
    }

    /// Compacts the heap; the lookahead snapshot's heap tops follow their objects.
    pub fn compact(state: *State) void {
        assert(state.strings.used <= state.strings.bytes.len);
        var string_tops = [1]u32{state.snapshot.strings_top};
        var list_tops = [1]u32{state.snapshot.lists_top};
        const marks: heap.Marks = if (state.snapshot.active)
            .{ .strings = &string_tops, .lists = &list_tops }
        else
            .{};
        _ = heap.compact(&state.strings, &state.lists, state, marks);
        assert(state.lists.used <= state.lists.words.len);
        if (state.snapshot.active) {
            state.snapshot.strings_top = string_tops[0];
            state.snapshot.lists_top = list_tops[0];
        }
        assert(state.snapshot.strings_top <= state.strings.used or !state.snapshot.active);
    }

    /// A hash of everything a story can observe or that later steps depend on: the live
    /// flow, the shared arrays and scalars, and the used heap. Values hash by tag and payload,
    /// so padding never counts. For tests of take and restore, and of determinism.
    pub fn hash(state: *const State) u64 {
        assert(state.memory.len > 0);
        var hasher: std.hash.Wyhash = .init(0);
        hash_values(&hasher, state.evaluation.slice());
        hash_values(&hasher, state.globals);
        hash_records(&hasher, state.call_stack.frames.slice());
        hash_records(&hasher, state.call_stack.threads.slice());
        hash_temps(&hasher, state.call_stack.temps.slice());
        hash_records(&hasher, state.output.items.slice());
        hash_records(&hasher, state.output.string_marks.slice());
        hash_records(&hasher, state.choices.records.slice());
        hash_records(&hasher, state.choices.tags.slice());
        hash_records(&hasher, state.choices.snapshots.slice());
        hash_records(&hasher, state.choices.frames.slice());
        hash_temps(&hasher, state.choices.temps.slice());
        hash_records(&hasher, state.visit_counts);
        hash_records(&hasher, state.turn_indices);
        hash_records(&hasher, state.observer_events.slice());
        hash_records(&hasher, state.errors.slice());
        hash_records(&hasher, state.warnings.slice());
        hasher.update(state.strings.bytes[0..state.strings.used]);
        hash_records(&hasher, state.lists.words[0..state.lists.used]);
        const scalars = [_]i32{
            state.turn_index,             @bitCast(state.call_stack.thread_counter),
            state.story_seed,             state.previous_random,
            @bitCast(state.current_flow), @intFromBool(state.snapshot.active),
        };
        hash_records(&hasher, &scalars);
        assert(state.lists.used <= state.lists.words.len);
        return hasher.final();
    }

    pub fn check(state: *State) Fault {
        assert(state.memory.len > 0);
        if (state.call_stack.check() != .ok) return .call_stack;
        if (state.output.check() != .ok) return .output;
        if (state.choices.check() != .ok) return .choices;
        if (state.strings.check() != .ok) return .strings;
        if (state.evaluation.check() != .ok) return .evaluation;
        if (state.visit_counts.len != state.program.count_slots_count) return .counts_length;
        var checker: ReferenceChecker = .{ .strings = &state.strings };
        state.visit(&checker);
        if (!checker.ok) return .string_reference;
        assert(state.turn_indices.len == state.visit_counts.len);
        return .ok;
    }

    pub fn verify(state: *State) void {
        assert(state.memory.len > 0);
        fault.verify(state.check());
    }
};

pub fn visit_values(values: []Value, visitor: anytype) void {
    assert(@TypeOf(visitor) != void);
    assert(values.len < std.math.maxInt(u32));
    for (values) |*value| {
        switch (value.*) {
            .string => |*reference| visitor.string(reference),
            .tag => |*reference| visitor.string(reference),
            .list => |*reference| visitor.list(reference),
            else => {},
        }
    }
}

pub fn visit_temps(temps: []Temp, visitor: anytype) void {
    assert(@TypeOf(visitor) != void);
    assert(temps.len < std.math.maxInt(u32));
    for (temps) |*temp| {
        switch (temp.value) {
            .string => |*reference| visitor.string(reference),
            .tag => |*reference| visitor.string(reference),
            .list => |*reference| visitor.list(reference),
            else => {},
        }
    }
}

fn hash_values(hasher: *std.hash.Wyhash, values: []const Value) void {
    assert(values.len < std.math.maxInt(u32));
    for (values) |value| hash_value(hasher, value);
    assert(@typeInfo(@TypeOf(hasher)) == .pointer);
}

fn hash_value(hasher: *std.hash.Wyhash, value: Value) void {
    assert(@sizeOf(Value) == 12);
    hasher.update(&.{@backingInt(value)});
    switch (value) {
        .null => {},
        .variable_pointer => |pointer| {
            std.hash.autoHash(hasher, pointer.name);
            std.hash.autoHash(hasher, pointer.context);
        },
        inline else => |payload| hasher.update(std.mem.asBytes(&payload)),
    }
}

fn hash_temps(hasher: *std.hash.Wyhash, temps: []const Temp) void {
    assert(temps.len < std.math.maxInt(u32));
    for (temps) |temp| {
        std.hash.autoHash(hasher, temp.name);
        hash_value(hasher, temp.value);
    }
    assert(@sizeOf(Temp) == element_bytes.temp);
}

/// Field by field, so struct padding never counts.
fn hash_records(hasher: *std.hash.Wyhash, records: anytype) void {
    assert(records.len < std.math.maxInt(u32));
    for (records) |record| std.hash.autoHash(hasher, record);
    assert(@typeInfo(@TypeOf(records)) == .pointer);
}

/// Checks that every heap string reference is valid (State.check).
const ReferenceChecker = struct {
    strings: *const heap.StringHeap,
    ok: bool = true,

    pub fn string(checker: *ReferenceChecker, reference: *StringReference) void {
        assert(@sizeOf(StringReference) == 4);
        assert(checker.strings.used <= checker.strings.bytes.len);
        if (!reference.is_heap()) return;
        if (checker.strings.check_reference(reference.*) != .ok) checker.ok = false;
    }

    pub fn list(checker: *ReferenceChecker, reference: *value_module.ListReference) void {
        assert(@sizeOf(value_module.ListReference) == 4);
        assert(checker.strings.used <= checker.strings.bytes.len);
        _ = reference;
    }
};

/// Hands out typed slices of one block, largest alignment first so nothing is padded.
const Carver = struct {
    memory: []align(8) u8,
    used: u32 = 0,

    fn take(carver: *Carver, comptime T: type, count: u32) []T {
        assert(carver.used % @alignOf(T) == 0);
        const bytes: u32 = count * @sizeOf(T);
        assert(carver.used + bytes <= carver.memory.len);
        const raw = carver.memory[carver.used..][0..bytes];
        const slice: []T = @alignCast(std.mem.bytesAsSlice(T, raw));
        carver.used += bytes;
        return slice;
    }
};

fn carve(carver: *Carver, program: *const Program, limits: Limits, memory: []align(8) u8) State {
    assert(carver.used == 0);
    const shape = State.shape_of(program);
    // 8-byte aligned first.
    const observers = carver.take(Observer, limits.observers_max);
    const live = carve_flow(carver, limits);
    const lookahead = carve_flow(carver, limits);
    const result: State = .{
        .program = program,
        .limits = limits,
        .memory = memory,
        .evaluation = .init(live.evaluation),
        .call_stack = .init(live.frames, live.threads, live.temps, limits.temps_per_frame_max),
        .output = .init(live.items, live.marks),
        .choices = .init(.{
            .records = live.choices,
            .tags = live.tags,
            .snapshots = live.snapshots,
            .frames = live.snapshot_frames,
            .temps = live.snapshot_temps,
        }),
        .globals = carver.take(Value, shape.globals_count),
        .global_defaults = carver.take(Value, shape.globals_count),
        .visit_counts = carver.take(u32, shape.count_slots),
        .turn_indices = carver.take(i32, shape.count_slots),
        .lists = .init(carver.take(u32, limits.list_words_max)),
        .observer_events = .init(carver.take(GlobalSlot, limits.observer_events_max)),
        .errors = .init(carver.take(Diagnostic, limits.errors_max)),
        .warnings = .init(carver.take(Diagnostic, limits.warnings_max)),
        .ancestors = carver.take(ContainerIndex, limits.container_depth_max),
        .lookahead = lookahead,
        .patch = carver.take(PatchEntry, limits.patch_entries_max),
        .flows = carver.take(FlowRecord, limits.flows_max),
        .parking = carver.take(u32, limits.flow_parking_bytes_max / 4),
        .strings = .init(carver.take(u8, limits.heap_bytes_max)),
        .line_bytes = carver.take(u8, limits.output_bytes_max),
        .observers = observers,
    };
    assert(result.globals.len == program.globals.len);
    return result;
}

fn carve_flow(carver: *Carver, limits: Limits) FlowBuffers {
    assert(carver.used % 4 == 0);
    const buffers: FlowBuffers = .{
        .evaluation = carver.take(Value, limits.evaluation_values_max),
        .frames = carver.take(Frame, limits.frames_max),
        .threads = carver.take(Thread, limits.threads_max),
        .temps = carver.take(Temp, limits.temps_max),
        .items = carver.take(output_module.Item, limits.output_items_max),
        .marks = carver.take(u32, limits.string_marks_max),
        .choices = carver.take(choices_module.Choice, limits.choices_max),
        .tags = carver.take(StringReference, limits.tags_max),
        .snapshots = carver.take(choices_module.Snapshot, limits.choices_max),
        .snapshot_frames = carver.take(Frame, limits.choice_snapshot_frames_max),
        .snapshot_temps = carver.take(Temp, limits.choice_snapshot_temps_max),
    };
    assert(buffers.frames.len == limits.frames_max);
    return buffers;
}

const CountingAllocator = @import("../core/counting_allocator.zig").CountingAllocator;
const ProgramBuilder = @import("../core/program_builder.zig").ProgramBuilder;

fn test_program(gpa: Allocator) !Program {
    assert(@sizeOf(State) > 0);
    var builder = try ProgramBuilder.init(gpa);
    defer builder.deinit();
    _ = try builder.begin_container(.{ .flags = .{ .visits_counted = true } });
    try builder.add(.global_get, try builder.global("score"));
    try builder.add(.done, {});
    try builder.end_container();
    const program = try builder.finish();
    assert(program.count_slots_count == 1);
    return program;
}

test "init allocates exactly the byte budget, once" {
    // Goal: P4.12; Story.init's memory is Limits.bytes_total, in one allocation. Method: a
    // counting allocator around init.
    const gpa = std.testing.allocator;
    var program = try test_program(gpa);
    defer program.deinit(gpa);
    var counting = CountingAllocator.init(gpa);
    var state: State = undefined;
    const limits: Limits = .{};
    try state.init(counting.allocator(), &program, limits);
    defer state.deinit(counting.allocator());
    try std.testing.expectEqual(@as(u64, 1), counting.allocations_count);
    try std.testing.expectEqual(limits.bytes_total(State.shape_of(&program)), counting.bytes_live);
    try std.testing.expectEqual(State.Fault.ok, state.check());
}

test "a fresh state starts at the root with nothing pending" {
    // Goal: reset matches ink's initial state. Method: inspect after init.
    const gpa = std.testing.allocator;
    var program = try test_program(gpa);
    defer program.deinit(gpa);
    var state: State = undefined;
    try state.init(gpa, &program, .{});
    defer state.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 1), state.call_stack.depth());
    try std.testing.expectEqual(Program.root, state.call_stack.current_frame().pointer.container);
    try std.testing.expectEqual(@as(i32, -1), state.turn_index);
    try std.testing.expectEqual(@as(u32, 0), state.visit_counts[0]);
    try std.testing.expectEqual(@as(u32, 0), state.choices.count());
}

test "check catches a dangling heap string" {
    // Goal: P4.11 negative space; a reference past the heap's used part. Method: put one in
    // the evaluation stack.
    const gpa = std.testing.allocator;
    var program = try test_program(gpa);
    defer program.deinit(gpa);
    var state: State = undefined;
    try state.init(gpa, &program, .{});
    defer state.deinit(gpa);
    try state.evaluation.push(.{ .string = .heap(64) });
    try std.testing.expectEqual(State.Fault.string_reference, state.check());
}
