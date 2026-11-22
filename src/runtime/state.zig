//! The runtime state of one story. Every buffer comes from one allocation of
//! exactly `Limits.bytes_total()` bytes, made in `init`; nothing allocates afterwards.
//!
//! The live flow (evaluation stack, call stack, output, choices) is what the lookahead
//! snapshot copies and what flows park. Globals, counts, the heap, the random
//! state and the diagnostics are shared by every flow.

const std = @import("std");
const assert = std.debug.assert;
const profile = @import("../core/profile.zig");
const Allocator = std.mem.Allocator;
const index = @import("../core/index.zig");
const limits_module = @import("../core/limits.zig");
const fault = @import("../core/fault.zig");
const pointer_free = @import("../core/pointer_free.zig");
const BoundedStack = @import("../core/bounded_stack.zig").BoundedStack;
const Program = @import("../core/program.zig").Program;
const value_module = @import("value.zig");
const heap = @import("heap.zig");
const lists_module = @import("lists.zig");
const call_stack_module = @import("call_stack.zig");
const output_module = @import("output.zig");
const choices_module = @import("choices.zig");
const flows = @import("flows.zig");
const json_tree = @import("json_tree.zig");
const lookahead_module = @import("lookahead.zig");
const text_cache_module = @import("text_cache.zig");
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

/// A kept runtime error or warning (ink's currentErrors and currentWarnings): its message,
/// formatted when it was raised, is `State.diagnostic_bytes[start..][0..length]`.
pub const Diagnostic = struct {
    start: u32,
    length: u32,

    pub const Severity = enum(u8) { @"error", warning };
};

/// A variable observer registered by the host.
pub const Observer = struct {
    callback: ?*const anyopaque,
    context: ?*anyopaque,
    slot: GlobalSlot,
};

/// A flow's directory entry. Flow names are stored inline.
pub const FlowRecord = struct {
    name: [flow_name_bytes_max]u8,
    parked_first: u32,
    parked_words: u32,
    thread_counter: u32,
    name_length: u8,
    in_use: bool,
};

pub const flow_name_bytes_max = 50;

/// The words of one external's binding (`story.Binding`, `element_bytes.binding`), which the
/// story keeps in this block, so `Story.init` makes one allocation.
pub const binding_words_each = element_bytes.binding / 8;

comptime {
    assert(element_bytes.binding % 8 == 0);
}

pub const output_stashes_max = 8;

/// A parked output stream: `items` items then `marks` string marks, from word `first`.
pub const OutputStash = struct {
    first: u32,
    items: u32,
    marks: u32,
};

/// A turn index for a container that has never been visited.
pub const never_visited: i32 = std.math.minInt(i32);

comptime {
    // What flows park, the lookahead snapshots and saves rebuild is copied by value: no
    // pointers (F11, docs/Guidelines.md).
    for (flow_buffers) |buffer| assert(pointer_free.has_no_pointers(FlowElement(buffer)));
    assert(pointer_free.has_no_pointers(Value));
    assert(pointer_free.has_no_pointers(Diagnostic));
    assert(pointer_free.has_no_pointers(FlowRecord));
    assert(pointer_free.has_no_pointers(GlobalSlot));
}

comptime {
    assert(@sizeOf(Diagnostic) == element_bytes.diagnostic);
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

    /// The first `counts[i]` elements of each buffer, in `flow_buffers` order.
    pub fn prefix(buffers: FlowBuffers, counts: *const [flow_buffers.len]u32) FlowBuffers {
        var result = buffers;
        inline for (flow_buffers, counts) |buffer, count| {
            const name = @tagName(buffer);
            assert(count <= @field(buffers, name).len);
            @field(result, name) = @field(buffers, name)[0..count];
        }
        return result;
    }
};

pub const FlowBuffer = limits_module.FlowBuffer;
/// Every per-flow buffer, in the order of `FlowBuffers`' fields.
pub const flow_buffers = std.enums.values(FlowBuffer);
/// The buffers a parked flow keeps: all but the evaluation stack, which flows share.
pub const parked_buffers = flow_buffers[1..];

pub fn FlowElement(comptime buffer: FlowBuffer) type {
    return @typeInfo(@FieldType(FlowBuffers, @tagName(buffer))).pointer.child;
}

/// `*BoundedStack` of a flow buffer's elements, const when the state is.
fn FlowStack(comptime StatePointer: type, comptime buffer: FlowBuffer) type {
    const Stack = BoundedStack(FlowElement(buffer));
    return if (StatePointer == *const State) *const Stack else *Stack;
}

comptime {
    const names = @typeInfo(FlowBuffers).@"struct".field_names;
    assert(names.len == flow_buffers.len);
    assert(parked_buffers[0] != .evaluation);
    for (names, flow_buffers) |name, buffer| {
        assert(std.mem.eql(u8, name, @tagName(buffer)));
        assert(@sizeOf(FlowElement(buffer)) == buffer.bytes_per_element());
        // Parking packs the buffers as words.
        assert(@sizeOf(FlowElement(buffer)) % 4 == 0);
        assert(@alignOf(FlowElement(buffer)) <= 4);
    }
}

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
    /// The turn each container was last visited in, or `never_visited` (ink keeps only
    /// visited ones; turn -1 is a real turn, before the first choice).
    turn_indices: []i32,
    turn_index: i32 = -1,
    story_seed: i32 = 0,
    previous_random: i32 = 0,
    strings: heap.StringHeap,
    lists: lists_module.ListSlab,
    /// Scratch for text being assembled (`/str`, tags) and for Debug checks.
    line_bytes: []u8,
    /// Scratch for one tag of the current line, cleaned, while it is passed to a tag sink
    /// (`Limits.tag_bytes_max`).
    tag_bytes: []u8,
    /// The current line's cleaned text, kept between calls.
    text_cache: text_cache_module.TextCache,
    observers: []Observer,
    /// The story's external bindings, as raw words (`Story.bindings` views them).
    binding_words: []u64,
    observer_events: BoundedStack(GlobalSlot),
    /// ink's currentErrors and currentWarnings. They are not saved (ink doesn't
    /// save them), the lookahead restore drops ones added since its snapshot, and
    /// `reset_errors` clears them once `cont()` has reported them.
    errors: BoundedStack(Diagnostic),
    warnings: BoundedStack(Diagnostic),
    /// The kept diagnostics' messages, in the order they were raised.
    diagnostic_bytes: []u8,
    diagnostic_bytes_used: u32 = 0,
    /// Diagnostics that didn't fit; reported as a count after the kept ones.
    diagnostics_dropped: u32 = 0,
    /// Scratch for the visit-counting walk.
    ancestors: []ContainerIndex,
    /// The fixed scratch `load_json` tokenizes a save into.
    load_nodes: []json_tree.Node,

    // The lookahead snapshot and parked flows.
    lookahead: FlowBuffers,
    /// The snapshot's copies of the shared arrays, as they were at `take`.
    lookahead_globals: []Value,
    lookahead_visit_counts: []u32,
    lookahead_turn_indices: []i32,
    /// One bit per chunk of the shared arrays (`lookahead.chunk_slots` globals, or visit
    /// counts and turn indices): set once the active snapshot has copied that chunk. Clear
    /// when no snapshot is active.
    lookahead_copied: []u32,
    flows: []FlowRecord,
    parking: []u32,
    current_flow: u32 = 0,
    /// Output streams set aside by evaluate_function (ink's outputStreamBefore), parked
    /// after the flows in `parking`; compaction roots.
    output_stashes: [output_stashes_max]OutputStash = undefined,
    output_stashes_count: u32 = 0,
    /// ink's didSafeExit: the flow ended at `DONE` or `END`, not by running out.
    did_safe_exit: bool = false,
    /// For the simulator: compact whenever room is reserved, so a reference held across a
    /// reservation without being a root shows up at once.
    compact_always: bool = false,
    snapshot: lookahead_module.Snapshot = .{},
    /// High-water marks of the buffers that aren't stacks (the stacks keep their own, and
    /// the heaps theirs); `usage` reports them all.
    peaks: Peaks = .{},

    pub const Peaks = struct {
        parking_words: u32 = 0,
        line_bytes: u32 = 0,
        tag_bytes: u32 = 0,
        load_nodes: u32 = 0,
        flows: u32 = 1,
    };

    pub const Fault = enum {
        ok,
        call_stack,
        output,
        choices,
        strings,
        evaluation,
        counts_length,
        string_reference,
        list_reference,
        flows,
        lookahead,
    };

    pub fn shape_of(program: *const Program) Limits.ProgramShape {
        assert(program.containers.len > 0);
        return .{
            .count_slots = program.count_slots_count,
            .globals_count = @intCast(program.globals.len),
            .externals_count = @intCast(program.externals.len),
        };
    }

    /// Allocates every buffer in one block of `limits.bytes_total()` bytes.
    pub fn init(state: *State, gpa: Allocator, program: *const Program, limits: Limits) !void {
        const profile_zone = profile.begin(.state_init);
        defer profile_zone.end();
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
        gpa.free(state.memory);
        state.* = undefined;
    }

    /// What this state has needed since init: every buffer's peak, and the deepest
    /// container nesting of the program (the visit-counting walk's scratch). Observers are
    /// the story's (`Story.usage`).
    pub fn usage(state: *const State) limits_module.Usage {
        const stack = &state.call_stack;
        const choices = &state.choices;
        const result: limits_module.Usage = .{
            .evaluation_values = state.evaluation.peak,
            .frames = stack.frames.peak,
            .threads = stack.threads.peak,
            .temps = stack.temps.peak,
            .output_items = state.output.items.peak,
            .output_bytes = state.peaks.line_bytes,
            .string_marks = state.output.string_marks.peak,
            .choices = choices.records.peak,
            .tags = choices.tags.peak,
            .tag_bytes = state.peaks.tag_bytes,
            .heap_bytes = state.strings.peak,
            .list_words = state.lists.peak,
            .flows = state.peaks.flows,
            .flow_parking_bytes = state.peaks.parking_words * 4,
            .choice_snapshot_frames = choices.frames.peak,
            .choice_snapshot_temps = choices.temps.peak,
            .observer_events = state.observer_events.peak,
            .errors = state.errors.peak,
            .warnings = state.warnings.peak,
            .container_depth = container_depth(state.program),
            .load_nodes = state.peaks.load_nodes,
        };
        assert(result.frames <= state.limits.frames_max);
        return result;
    }

    /// The story's starting state: one thread at the root, empty output and choices, zeroed
    /// counts, globals undefined until the global declaration has run.
    pub fn reset(state: *State) void {
        state.evaluation.clear();
        state.call_stack.fresh(.start_of(Program.root));
        state.output.clear();
        state.choices.clear();
        @memset(state.globals, .null);
        @memset(state.global_defaults, .null);
        @memset(state.visit_counts, 0);
        @memset(state.turn_indices, never_visited);
        state.turn_index = -1;
        state.previous_random = 0;
        state.strings.used = 0;
        state.strings.generation +%= 1;
        state.text_cache.clear();
        state.lists.used = 0;
        state.observer_events.clear();
        state.errors.clear();
        state.reset_errors();
        state.did_safe_exit = false;
        state.output_stashes_count = 0;
        state.snapshot = .{};
        @memset(state.lookahead_copied, 0);
        flows.reset(state);
        state.verify();
    }

    /// The live stack behind flow buffer `buffer`.
    pub fn flow_stack(
        state: anytype,
        comptime buffer: FlowBuffer,
    ) FlowStack(@TypeOf(state), buffer) {
        comptime assert(@typeInfo(@TypeOf(state)).pointer.child == State);
        return switch (buffer) {
            .evaluation => &state.evaluation,
            .frames => &state.call_stack.frames,
            .threads => &state.call_stack.threads,
            .temps => &state.call_stack.temps,
            .items => &state.output.items,
            .marks => &state.output.string_marks,
            .choices => &state.choices.records,
            .tags => &state.choices.tags,
            .snapshots => &state.choices.snapshots,
            .snapshot_frames => &state.choices.frames,
            .snapshot_temps => &state.choices.temps,
        };
    }

    /// The used part of every live-flow buffer.
    pub fn live_flow(state: *State) FlowBuffers {
        assert(state.call_stack.threads.count > 0);
        var buffers: FlowBuffers = undefined;
        inline for (flow_buffers) |buffer| {
            @field(buffers, @tagName(buffer)) = state.flow_stack(buffer).slice();
        }
        return buffers;
    }

    /// Calls `visitor.string` and `visitor.list` for every heap reference the state holds:
    /// the root set of heap compaction.
    pub fn visit(state: *State, visitor: anytype) void {
        assert(@TypeOf(visitor) != void);
        visit_flow(state.live_flow(), visitor);
        for (state.globals) |*value| visit_value(value, visitor);
        for (state.global_defaults) |*value| visit_value(value, visitor);
        flows.visit_parked(state, visitor);
        for (state.output_stashes[0..state.output_stashes_count]) |stash| {
            const words = state.parking[stash.first..][0 .. stash.items * 3];
            visit_items(@alignCast(std.mem.bytesAsSlice(
                output_module.Item,
                std.mem.sliceAsBytes(words),
            )), visitor);
        }
        lookahead_module.visit(state, visitor);
    }

    /// ink's AddError: formats the message now, with ink's prefix from Story.AddError. Compiled
    /// JSON has no debug metadata, so the prefix is `RUNTIME ERROR: (<pointer path>): ` while
    /// the story has a pointer, else `RUNTIME ERROR: `. When the list is full the diagnostic
    /// is counted, not kept: the first ones are usually the cause of the rest. A message
    /// longer than the bytes left is cut short.
    pub fn add_diagnostic(
        state: *State,
        severity: Diagnostic.Severity,
        pointer: call_stack_module.Pointer,
        comptime format: []const u8,
        arguments: anytype,
    ) void {
        const list = switch (severity) {
            .@"error" => &state.errors,
            .warning => &state.warnings,
        };
        assert(list.buffer.len > 0);
        assert(state.diagnostic_bytes_used <= state.diagnostic_bytes.len);
        if (list.is_full()) {
            state.diagnostics_dropped += 1;
            return;
        }
        const start = state.diagnostic_bytes_used;
        var writer: std.Io.Writer = .fixed(state.diagnostic_bytes[start..]);
        write_diagnostic(state.program, severity, pointer, format, arguments, &writer) catch {};
        state.diagnostic_bytes_used += @intCast(writer.end);
        list.push(.{ .start = start, .length = @intCast(writer.end) }) catch unreachable;
        assert(list.count > 0);
    }

    pub fn diagnostic_text(state: *const State, diagnostic: Diagnostic) []const u8 {
        assert(diagnostic.start + diagnostic.length <= state.diagnostic_bytes_used);
        return state.diagnostic_bytes[diagnostic.start..][0..diagnostic.length];
    }

    /// ink's hasError, which also stops `can_continue`.
    pub fn has_error(state: *const State) bool {
        assert(state.errors.count <= state.errors.buffer.len);
        // Limits are never zero, so a dropped error always has a kept one before it.
        assert(state.errors.buffer.len > 0);
        return state.errors.count > 0;
    }

    pub fn has_warning(state: *const State) bool {
        assert(state.warnings.count <= state.warnings.buffer.len);
        return state.warnings.count > 0;
    }

    /// ink's ResetErrors.
    pub fn reset_errors(state: *State) void {
        assert(state.errors.buffer.len > 0 and state.warnings.buffer.len > 0);
        state.errors.clear();
        state.warnings.clear();
        state.diagnostic_bytes_used = 0;
        state.diagnostics_dropped = 0;
        assert(!state.has_error() and !state.has_warning());
    }

    /// Compacts the heap; the lookahead snapshot's heap tops follow their objects. Only
    /// `reserve` (and load) calls it, while the roots hold every live value.
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

    /// Room for `string_bytes` of heap strings (headers included) and `list_words` of lists,
    /// compacting first if either is short. Compaction moves what it can reach from the
    /// roots, so the caller must hold no heap value outside them: an instruction reserves
    /// before it pops its operands. `usage` counts the room asked for.
    pub fn reserve(
        state: *State,
        string_bytes: u32,
        list_words: u32,
    ) error{ HeapLimit, ListLimit }!void {
        assert(state.strings.used <= state.strings.bytes.len);
        assert(state.lists.used <= state.lists.words.len);
        const strings_short = state.strings.bytes.len - state.strings.used < string_bytes;
        const lists_short = state.lists.words.len - state.lists.used < list_words;
        if (strings_short or lists_short or state.compact_always) state.compact();
        state.strings.note_need(string_bytes);
        state.lists.note_need(list_words);
        if (state.strings.bytes.len - state.strings.used < string_bytes) return error.HeapLimit;
        if (state.lists.words.len - state.lists.used < list_words) return error.ListLimit;
    }

    // lint: allow hot_path: tests and fuzz targets compare states; the step never hashes
    /// A hash of everything a story can observe or that later steps depend on: the live
    /// flow, the shared arrays and scalars, and the used heap. Values hash by tag and payload,
    /// so padding never counts. For tests of take and restore, and of determinism.
    pub fn hash(state: *const State) u64 {
        var hasher: std.hash.Wyhash = .init(0);
        inline for (flow_buffers) |buffer| {
            const elements = state.flow_stack(buffer).slice();
            switch (FlowElement(buffer)) {
                Value => hash_values(&hasher, elements),
                Temp => hash_temps(&hasher, elements),
                else => hash_records(&hasher, elements),
            }
        }
        hash_values(&hasher, state.globals);
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
        if (state.call_stack.check() != .ok) return .call_stack;
        if (state.output.check() != .ok) return .output;
        if (state.choices.check() != .ok) return .choices;
        if (state.strings.check() != .ok) return .strings;
        if (state.evaluation.check() != .ok) return .evaluation;
        if (state.visit_counts.len != state.program.count_slots_count) return .counts_length;
        if (flows.check(state) != .ok) return .flows;
        if (lookahead_module.check(state) != .ok) return .lookahead;
        var checker: ReferenceChecker = .{ .strings = &state.strings, .lists = &state.lists };
        state.visit(&checker);
        if (!checker.strings_ok) return .string_reference;
        if (!checker.lists_ok) return .list_reference;
        assert(state.turn_indices.len == state.visit_counts.len);
        return .ok;
    }

    pub fn verify(state: *State) void {
        fault.verify(state.check());
    }
};

/// Visits the heap references in one flow's buffers, live, copied or parked.
pub fn visit_flow(buffers: FlowBuffers, visitor: anytype) void {
    assert(buffers.snapshots.len <= buffers.choices.len);
    for (buffers.evaluation) |*value| visit_value(value, visitor);
    for (buffers.temps) |*temp| visit_value(&temp.value, visitor);
    visit_items(buffers.items, visitor);
    for (buffers.choices) |*choice| visitor.string(&choice.text);
    for (buffers.tags) |*tag| visitor.string(tag);
    for (buffers.snapshot_temps) |*temp| visit_value(&temp.value, visitor);
}

fn visit_items(items: []output_module.Item, visitor: anytype) void {
    for (items) |*item| {
        if (item.kind == .text or item.kind == .tag) visitor.string(&item.string);
    }
}

/// Calls `visitor.string` or `visitor.list` for the heap reference `value` holds, if any.
pub fn visit_value(value: *Value, visitor: anytype) void {
    assert(@TypeOf(visitor) != void);
    switch (value.*) {
        .string => |*reference| visitor.string(reference),
        .tag => |*reference| visitor.string(reference),
        .list => |*reference| visitor.list(reference),
        else => {},
    }
}

// lint: allow hot_path: State.hash, for tests
fn hash_values(hasher: *std.hash.Wyhash, values: []const Value) void {
    for (values) |value| hash_value(hasher, value);
    assert(@typeInfo(@TypeOf(hasher)) == .pointer);
}

// lint: allow hot_path: State.hash, for tests
fn hash_value(hasher: *std.hash.Wyhash, value: Value) void {
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

// lint: allow hot_path: State.hash, for tests
fn hash_temps(hasher: *std.hash.Wyhash, temps: []const Temp) void {
    for (temps) |temp| {
        std.hash.autoHash(hasher, temp.name);
        hash_value(hasher, temp.value);
    }
}

/// Field by field, so struct padding never counts.
// lint: allow hot_path: State.hash, for tests
fn hash_records(hasher: *std.hash.Wyhash, records: anytype) void {
    for (records) |record| std.hash.autoHash(hasher, record);
    assert(@typeInfo(@TypeOf(records)) == .pointer);
}

/// Checks that every heap string reference is valid (State.check).
const ReferenceChecker = struct {
    strings: *const heap.StringHeap,
    lists: *const lists_module.ListSlab,
    strings_ok: bool = true,
    lists_ok: bool = true,

    pub fn string(checker: *ReferenceChecker, reference: *StringReference) void {
        assert(checker.strings.used <= checker.strings.bytes.len);
        if (!reference.is_heap()) return;
        if (checker.strings.check_reference(reference.*) != .ok) checker.strings_ok = false;
    }

    pub fn list(checker: *ReferenceChecker, reference: *value_module.ListReference) void {
        assert(checker.lists.used <= checker.lists.words.len);
        if (!checker.lists.check_reference(reference.*)) checker.lists_ok = false;
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

fn write_diagnostic(
    program: *const Program,
    severity: Diagnostic.Severity,
    pointer: call_stack_module.Pointer,
    comptime format: []const u8,
    arguments: anytype,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    const kind = if (severity == .@"error") "ERROR" else "WARNING";
    try writer.print("RUNTIME {s}: ", .{kind});
    if (!pointer.is_null()) {
        const path = program.strings.get(program.container_info(pointer.container).path);
        if (path.len == 0) {
            try writer.print("({d}): ", .{pointer.index});
        } else {
            try writer.print("({s}.{d}): ", .{ path, pointer.index });
        }
    }
    try writer.print(format, arguments);
}

/// The deepest nesting of containers in the program (root alone is 1).
fn container_depth(program: *const Program) u32 {
    assert(program.containers.len > 0);
    var deepest: u32 = 0;
    for (0..program.containers.len) |position| {
        var depth: u32 = 0;
        var container: ContainerIndex = .from_int(@intCast(position));
        while (!container.is_none()) : (depth += 1) container = program.parent(container);
        deepest = @max(deepest, depth);
    }
    assert(deepest >= 1);
    return deepest;
}

fn carve(carver: *Carver, program: *const Program, limits: Limits, memory: []align(8) u8) State {
    assert(carver.used == 0);
    const shape = State.shape_of(program);
    // 8-byte aligned first.
    const observers = carver.take(Observer, limits.observers_max);
    const binding_words = carver.take(u64, shape.externals_count * binding_words_each);
    const live = carve_flow(carver, limits);
    const lookahead = carve_flow(carver, limits);
    var result: State = .{
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
        .lookahead_globals = carver.take(Value, shape.globals_count),
        .lookahead_visit_counts = carver.take(u32, shape.count_slots),
        .lookahead_turn_indices = carver.take(i32, shape.count_slots),
        .lookahead_copied = carver.take(u32, shape.lookahead_copied_words()),
        .lists = .init(carver.take(u32, limits.list_words_max)),
        .observer_events = .init(carver.take(GlobalSlot, limits.observer_events_max)),
        .errors = .init(carver.take(Diagnostic, limits.errors_max)),
        .warnings = .init(carver.take(Diagnostic, limits.warnings_max)),
        .ancestors = carver.take(ContainerIndex, limits.container_depth_max),
        .load_nodes = carver.take(json_tree.Node, limits.load_nodes_max),
        .lookahead = lookahead,
        .flows = carver.take(FlowRecord, limits.flows_max),
        .parking = carver.take(u32, limits.flow_parking_bytes_max / 4),
        // The cache's items here, for alignment; its bytes after `line_bytes`.
        .text_cache = .{
            .items = carver.take(output_module.Item, limits.output_items_max),
            .text = &.{},
        },
        .strings = .init(carver.take(u8, limits.heap_bytes_max)),
        .line_bytes = carver.take(u8, limits.output_bytes_max),
        .tag_bytes = carver.take(u8, limits.tag_bytes_max),
        .diagnostic_bytes = carver.take(
            u8,
            (limits.errors_max + limits.warnings_max) * element_bytes.diagnostic_text,
        ),
        .observers = observers,
        .binding_words = binding_words,
    };
    result.text_cache.text = carver.take(u8, limits.output_bytes_max);
    assert(result.text_cache.check() == .ok);
    assert(result.globals.len == program.globals.len);
    return result;
}

fn carve_flow(carver: *Carver, limits: Limits) FlowBuffers {
    assert(carver.used % 4 == 0);
    var buffers: FlowBuffers = undefined;
    inline for (flow_buffers) |buffer| {
        const count = buffer.capacity(&limits);
        @field(buffers, @tagName(buffer)) = carver.take(FlowElement(buffer), count);
    }
    assert(buffers.frames.len == limits.frames_max);
    return buffers;
}

const CountingAllocator = @import("../core/counting_allocator.zig").CountingAllocator;
const ProgramBuilder = @import("../core/program_builder.zig").ProgramBuilder;

fn test_program(gpa: Allocator) !Program {
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
    // Story.init's memory is Limits.bytes_total, in one allocation: a
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

test "the flow buffer table covers every FlowBuffers field, each with its own live stack" {
    // Lookahead, parking, save and load iterate `flow_buffers`, so a buffer missing
    // from it would silently not be copied. Every FlowBuffers field has a tag whose
    // live stack and lookahead copy are sized from its limit, and no two tags share a stack.
    const gpa = std.testing.allocator;
    var program = try test_program(gpa);
    defer program.deinit(gpa);
    var state: State = undefined;
    const limits: Limits = limits_module.small_story_limits;
    try state.init(gpa, &program, limits);
    defer state.deinit(gpa);
    var starts: [flow_buffers.len]usize = undefined;
    inline for (@typeInfo(FlowBuffers).@"struct".field_names, 0..) |name, position| {
        const buffer = @field(FlowBuffer, name);
        const stack = state.flow_stack(buffer);
        try std.testing.expectEqual(buffer.capacity(&limits), stack.capacity());
        try std.testing.expectEqual(stack.buffer.len, @field(state.lookahead, name).len);
        starts[position] = @intFromPtr(stack.buffer.ptr);
        for (starts[0..position]) |other| try std.testing.expect(other != starts[position]);
    }
    const live = state.live_flow();
    try std.testing.expectEqual(state.call_stack.frames.buffer.ptr, live.frames.ptr);
    try std.testing.expectEqual(@as(usize, 1), live.threads.len);
}

test "a fresh state starts at the root with nothing pending" {
    // Reset matches ink's initial state: inspect after init.
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
    // Negative space; a reference past the heap's used part: put one in
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

test "errors and warnings are bounded and reset together" {
    // Ink's AddError, hasError and ResetErrors, within errors_max: add
    // more errors than fit, then a warning, then reset. Messages are formatted when added.
    const gpa = std.testing.allocator;
    var program = try test_program(gpa);
    defer program.deinit(gpa);
    var state: State = undefined;
    try state.init(gpa, &program, .{ .errors_max = 2, .warnings_max = 1 });
    defer state.deinit(gpa);
    try std.testing.expect(!state.has_error());
    for (0..3) |position| state.add_diagnostic(.@"error", .null, "error {d}", .{position});
    try std.testing.expect(state.has_error() and !state.has_warning());
    try std.testing.expectEqual(@as(u32, 2), state.errors.count);
    try std.testing.expectEqual(@as(u32, 1), state.diagnostics_dropped);
    const second = state.diagnostic_text(state.errors.slice()[1]);
    try std.testing.expectEqualStrings("RUNTIME ERROR: error 1", second);
    state.add_diagnostic(.warning, .start_of(Program.root), "careful", .{});
    try std.testing.expect(state.has_warning());
    const warning = state.diagnostic_text(state.warnings.slice()[0]);
    try std.testing.expectEqualStrings("RUNTIME WARNING: (0): careful", warning);
    state.reset_errors();
    try std.testing.expect(!state.has_error() and !state.has_warning());
    try std.testing.expectEqual(@as(u32, 0), state.diagnostics_dropped);
    try std.testing.expectEqual(@as(u32, 0), state.diagnostic_bytes_used);
}

test "a reservation compacts only when short, and the roots keep their values" {
    // Trigger; room is reserved before an instruction pops anything, so a
    // value on a root survives the compaction and garbage goes. Fill a small heap with
    // garbage and one string in a global.
    const gpa = std.testing.allocator;
    var program = try test_program(gpa);
    defer program.deinit(gpa);
    var state: State = undefined;
    try state.init(gpa, &program, .{ .heap_bytes_max = 64, .list_words_max = 8 });
    defer state.deinit(gpa);
    _ = state.strings.try_allocate(16).?; // 24 bytes with the header
    const kept = state.strings.try_allocate(4).?;
    @memcpy(state.strings.get(kept), "kept");
    state.globals[0] = .{ .string = kept };
    _ = state.strings.try_allocate(12).?; // 56 of 64 bytes used
    try state.reserve(8, 0);
    try std.testing.expectEqual(@as(u32, 56), state.strings.used); // it fit: no compaction
    try state.reserve(32, 0);
    try std.testing.expectEqual(@as(u32, 12), state.strings.used);
    try std.testing.expectEqualStrings("kept", state.strings.get(state.globals[0].string));
    try std.testing.expectError(error.HeapLimit, state.reserve(56, 0));
    _ = try state.lists.store(&.{.from_int(1)}, &.{});
    state.globals[0] = .{ .list = try state.lists.store(&.{.from_int(2)}, &.{}) };
    try state.reserve(0, 4);
    const items = state.lists.view(state.globals[0].list).items;
    try std.testing.expectEqual(@as(u32, 2), items[0].to_int());
    try std.testing.expectError(error.ListLimit, state.reserve(0, 5));
}
