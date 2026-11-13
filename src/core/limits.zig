//! Limits on everything. `Story.Options.limits` and `Compiler.Options.limits`
//! override the defaults at runtime; every buffer is sized from them once, at init.
//!
//! `element_bytes` records the planned size of each buffer element. Each real type asserts
//! `@sizeOf(T) == element_bytes.x` at compile time, so `bytes_total` stays exact.

const std = @import("std");
const assert = std.debug.assert;
const fault = @import("fault.zig");

/// Planned element sizes in bytes. Checked by each type's comptime assert.
pub const element_bytes = struct {
    pub const value = 12;
    pub const frame = 24;
    pub const thread = 20; // frame range, counter, previous pointer
    pub const temp = 16; // name: StringId + Value
    pub const output_item = 12;
    pub const string_mark = 4;
    pub const choice = 40; // text, target, source, threads, tags, snapshot, flags
    pub const tag = 4; // StringReference
    pub const list_word = 4;
    pub const patch_entry = 16;
    pub const flow = 64; // name, directory ranges into the parking region
    pub const observer = 24; // global slot, callback, context
    pub const observer_event = 4; // GlobalSlot
    pub const diagnostic = 24; // argument, two numbers, pointer, code, severity
    pub const count_slot = 8; // visit count u32 + turn index i32
    pub const global = value * 2; // current value + default value
    pub const ancestor = 4; // ContainerIndex, for the visit-counting walk
    pub const snapshot = 24; // a choice's stored thread: frame and temp ranges, previous pointer
    pub const load_node = 16; // a token of a save being loaded (vm/json_tree.zig)
};

/// Bounds for one story instance. Every field is a maximum count unless its name says bytes.
pub const Limits = struct {
    evaluation_values_max: u32 = 1024,
    frames_max: u32 = 1024,
    threads_max: u32 = 64,
    temps_max: u32 = 4096,
    temps_per_frame_max: u32 = 256,
    output_items_max: u32 = 4096,
    output_bytes_max: u32 = 64 * 1024,
    string_marks_max: u32 = 64,
    choices_max: u32 = 64,
    tags_max: u32 = 256,
    heap_bytes_max: u32 = 1024 * 1024,
    list_words_max: u32 = 16 * 1024,
    flows_max: u32 = 8,
    flow_parking_bytes_max: u32 = 256 * 1024,
    choice_snapshot_frames_max: u32 = 256,
    choice_snapshot_temps_max: u32 = 1024,
    patch_entries_max: u32 = 1024,
    observers_max: u32 = 64,
    observer_events_max: u32 = 256,
    errors_max: u32 = 32,
    warnings_max: u32 = 32,
    steps_per_continue_max: u32 = 1_000_000,
    evaluate_depth_max: u32 = 4,
    container_depth_max: u32 = 256,
    path_components_max: u32 = 64,
    /// Tokens of a save document `load_json` can hold (its fixed scratch).
    load_nodes_max: u32 = 16 * 1024,

    pub const Fault = enum {
        ok,
        zero_limit,
        temps_per_frame_exceed_temps,
        threads_exceed_frames,
        choice_snapshot_frames_exceed_frames,
        output_items_exceed_output_bytes,
        evaluate_depth_exceeds_frames,
        bytes_total_overflow,
    };

    /// Counts that depend on the loaded program rather than on the limits.
    pub const ProgramShape = struct {
        count_slots: u32,
        globals_count: u32,
    };

    pub fn check(limits: *const Limits) Fault {
        const info = @typeInfo(Limits).@"struct";
        inline for (info.field_names, info.field_types) |name, Field| {
            comptime assert(Field == u32);
            if (@field(limits, name) == 0) return .zero_limit;
        }
        if (limits.temps_per_frame_max > limits.temps_max) return .temps_per_frame_exceed_temps;
        if (limits.threads_max > limits.frames_max) return .threads_exceed_frames;
        if (limits.choice_snapshot_frames_max > limits.frames_max * limits.choices_max) {
            return .choice_snapshot_frames_exceed_frames;
        }
        // Each output item covers at least one byte of text, so more items than bytes is waste.
        if (limits.output_items_max > limits.output_bytes_max) {
            return .output_items_exceed_output_bytes;
        }
        if (limits.evaluate_depth_max > limits.frames_max) return .evaluate_depth_exceeds_frames;
        const shape: ProgramShape = .{ .count_slots = 0, .globals_count = 0 };
        if (limits.bytes_total_checked(shape) == null) return .bytes_total_overflow;
        assert(limits.frames_max >= limits.threads_max);
        assert(limits.temps_max >= limits.temps_per_frame_max);
        return .ok;
    }

    pub fn verify(limits: *const Limits) void {
        assert(@sizeOf(Limits) == @typeInfo(Limits).@"struct".field_names.len * 4);
        fault.verify(limits.check());
    }

    /// The exact number of bytes `Story.init` allocates for these limits and program.
    pub fn bytes_total(limits: *const Limits, shape: ProgramShape) u64 {
        limits.verify();
        const total = limits.bytes_total_checked(shape).?;
        assert(total >= limits.heap_bytes_max);
        return total;
    }

    fn bytes_total_checked(limits: *const Limits, shape: ProgramShape) ?u64 {
        const live = limits.live_flow_bytes();
        // The lookahead snapshot is a second copy of the live-flow buffers.
        const lookahead = live + @as(u64, limits.patch_entries_max) * element_bytes.patch_entry;
        const shared = limits.shared_bytes(shape);
        const total = std.math.add(u64, live, lookahead) catch return null;
        const result = std.math.add(u64, total, shared) catch return null;
        assert(result >= live);
        assert(result >= shared);
        return result;
    }

    /// Buffers that belong to the active flow: call stack, evaluation, output and choices.
    pub fn live_flow_bytes(limits: *const Limits) u64 {
        var total: u64 = 0;
        for (std.enums.values(FlowBuffer)) |buffer| {
            total += @as(u64, buffer.capacity(limits)) * buffer.bytes_per_element();
        }
        assert(total > limits.evaluation_values_max);
        assert(total < std.math.maxInt(u64) / 4);
        return total;
    }

    /// Buffers shared by all flows: globals, counts, the heap, flows and diagnostics.
    pub fn shared_bytes(limits: *const Limits, shape: ProgramShape) u64 {
        const bytes = element_bytes;
        var total: u64 = 0;
        total += @as(u64, shape.globals_count) * bytes.global;
        total += @as(u64, shape.count_slots) * bytes.count_slot;
        total += limits.output_bytes_max;
        // The cleaned-text cache: a copy of the cleaned items and their text.
        total += @as(u64, limits.output_items_max) * bytes.output_item + limits.output_bytes_max;
        total += limits.heap_bytes_max;
        total += @as(u64, limits.list_words_max) * bytes.list_word;
        total += @as(u64, limits.flows_max) * bytes.flow;
        total += limits.flow_parking_bytes_max;
        total += @as(u64, limits.observers_max) * bytes.observer;
        total += @as(u64, limits.observer_events_max) * bytes.observer_event;
        total += @as(u64, limits.errors_max + limits.warnings_max) * bytes.diagnostic;
        total += @as(u64, limits.container_depth_max) * bytes.ancestor;
        total += @as(u64, limits.load_nodes_max) * bytes.load_node;
        assert(total >= limits.heap_bytes_max);
        assert(total < std.math.maxInt(u64) / 4);
        return total;
    }
};

/// The buffers of one live flow, in the order they are carved and parked. The runtime's
/// `FlowBuffers` has one field per tag; the lookahead copies all of them, and a parked flow
/// all but the evaluation stack, which flows share.
pub const FlowBuffer = enum {
    evaluation,
    frames,
    threads,
    temps,
    items,
    marks,
    choices,
    tags,
    snapshots,
    snapshot_frames,
    snapshot_temps,

    pub fn capacity(buffer: FlowBuffer, limits: *const Limits) u32 {
        return switch (buffer) {
            .evaluation => limits.evaluation_values_max,
            .frames => limits.frames_max,
            .threads => limits.threads_max,
            .temps => limits.temps_max,
            .items => limits.output_items_max,
            .marks => limits.string_marks_max,
            .choices, .snapshots => limits.choices_max,
            .tags => limits.tags_max,
            .snapshot_frames => limits.choice_snapshot_frames_max,
            .snapshot_temps => limits.choice_snapshot_temps_max,
        };
    }

    pub fn bytes_per_element(buffer: FlowBuffer) u32 {
        const bytes = element_bytes;
        return switch (buffer) {
            .evaluation => bytes.value,
            .frames, .snapshot_frames => bytes.frame,
            .threads => bytes.thread,
            .temps, .snapshot_temps => bytes.temp,
            .items => bytes.output_item,
            .marks => bytes.string_mark,
            .choices => bytes.choice,
            .tags => bytes.tag,
            .snapshots => bytes.snapshot,
        };
    }
};

/// What a story instance needed: the peak of every limit that sizes a buffer, in
/// that limit's unit. `Limits.fitted` turns it into limits with a margin.
pub const Usage = struct {
    evaluation_values: u32 = 0,
    frames: u32 = 0,
    threads: u32 = 0,
    temps: u32 = 0,
    output_items: u32 = 0,
    output_bytes: u32 = 0,
    string_marks: u32 = 0,
    choices: u32 = 0,
    tags: u32 = 0,
    heap_bytes: u32 = 0,
    list_words: u32 = 0,
    flows: u32 = 0,
    flow_parking_bytes: u32 = 0,
    choice_snapshot_frames: u32 = 0,
    choice_snapshot_temps: u32 = 0,
    patch_entries: u32 = 0,
    observers: u32 = 0,
    observer_events: u32 = 0,
    errors: u32 = 0,
    warnings: u32 = 0,
    container_depth: u32 = 0,
    load_nodes: u32 = 0,
};

/// The smallest value `Limits.fitted` gives a buffer, so a story that never used one (no
/// errors, no saves loaded) still gets a few slots.
const fitted_floor = 8;

/// Limits sized from measured usage: each buffer gets its peak times `margin` (at least
/// `fitted_floor`); limits that size no buffer keep their defaults where consistent.
pub fn fitted(usage: Usage, margin: u32) Limits {
    assert(margin >= 1);
    assert(margin <= 16);
    var limits: Limits = .{};
    inline for (@typeInfo(Usage).@"struct".field_names) |name| {
        const scaled = std.math.mul(u32, @field(usage, name), margin) catch std.math.maxInt(u32);
        @field(limits, name ++ "_max") = @max(fitted_floor, scaled);
    }
    limits.heap_bytes_max = std.mem.alignForward(u32, limits.heap_bytes_max, 4);
    limits.flow_parking_bytes_max = std.mem.alignForward(u32, limits.flow_parking_bytes_max, 4);
    limits.output_bytes_max = @max(limits.output_bytes_max, limits.output_items_max);
    limits.frames_max = @max(limits.frames_max, limits.threads_max);
    limits.temps_per_frame_max = @min(limits.temps_per_frame_max, limits.temps_max);
    limits.evaluate_depth_max = @min(limits.evaluate_depth_max, limits.frames_max);
    const snapshot_frames_max = limits.frames_max * limits.choices_max;
    const snapshot_frames = limits.choice_snapshot_frames_max;
    limits.choice_snapshot_frames_max = @min(snapshot_frames, snapshot_frames_max);
    assert(limits.check() == .ok);
    return limits;
}

/// Bounds for one compilation.
pub const CompilerLimits = struct {
    source_bytes_max: u32 = 16 * 1024 * 1024,
    /// Rule frames; ink's grammar takes about ten per level of brace nesting.
    parse_depth_max: u32 = 512,
    diagnostics_max: u32 = 256,
    include_depth_max: u32 = 16,
    include_files_max: u32 = 256,
    compile_retries_max: u32 = 3,

    pub const Fault = enum { ok, zero_limit, retries_unbounded };

    pub fn check(limits: *const CompilerLimits) Fault {
        const info = @typeInfo(CompilerLimits).@"struct";
        inline for (info.field_names, info.field_types) |name, Field| {
            comptime assert(Field == u32);
            if (@field(limits, name) == 0) return .zero_limit;
        }
        // Each retry doubles the workspace; more than a few means a sizing bug.
        if (limits.compile_retries_max > 8) return .retries_unbounded;
        assert(limits.parse_depth_max > 0);
        return .ok;
    }

    pub fn verify(limits: *const CompilerLimits) void {
        assert(limits.source_bytes_max > 0);
        fault.verify(limits.check());
    }
};

comptime {
    const defaults: Limits = .{};
    assert(defaults.check() == .ok);
    const compiler_defaults: CompilerLimits = .{};
    assert(compiler_defaults.check() == .ok);
}

test "default limits are consistent" {
    // The defaults pass their own check: check both limit sets.
    const limits: Limits = .{};
    try std.testing.expectEqual(Limits.Fault.ok, limits.check());
    const compiler: CompilerLimits = .{};
    try std.testing.expectEqual(CompilerLimits.Fault.ok, compiler.check());
}

test "inconsistent limits are rejected by name" {
    // Negative space; each relationship has its own fault: break one at a time.
    var limits: Limits = .{};
    limits.frames_max = 0;
    try std.testing.expectEqual(Limits.Fault.zero_limit, limits.check());
    limits = .{};
    limits.temps_per_frame_max = limits.temps_max + 1;
    try std.testing.expectEqual(Limits.Fault.temps_per_frame_exceed_temps, limits.check());
    limits = .{};
    limits.threads_max = limits.frames_max + 1;
    try std.testing.expectEqual(Limits.Fault.threads_exceed_frames, limits.check());
    limits = .{};
    limits.output_items_max = limits.output_bytes_max + 1;
    try std.testing.expectEqual(Limits.Fault.output_items_exceed_output_bytes, limits.check());
    limits = .{};
    limits.evaluate_depth_max = limits.frames_max + 1;
    try std.testing.expectEqual(Limits.Fault.evaluate_depth_exceeds_frames, limits.check());
    var compiler: CompilerLimits = .{};
    compiler.compile_retries_max = 9;
    try std.testing.expectEqual(CompilerLimits.Fault.retries_unbounded, compiler.check());
}

test "the default byte budget is pinned" {
    // Any change to limits or element sizes shows up here and gets a conscious update.
    // Compute the budget for the defaults and a small program shape.
    const limits: Limits = .{};
    const shape: Limits.ProgramShape = .{ .count_slots = 100, .globals_count = 20 };
    try std.testing.expectEqual(@as(u64, 2_203_392), limits.bytes_total(shape));
}

/// The limits of docs/benchmarks.md's sizing example for small side stories.
pub const small_story_limits: Limits = .{
    .evaluation_values_max = 256,
    .frames_max = 128,
    .threads_max = 16,
    .temps_max = 512,
    .temps_per_frame_max = 64,
    .output_items_max = 512,
    .output_bytes_max = 8 * 1024,
    .string_marks_max = 16,
    .choices_max = 16,
    .tags_max = 64,
    .heap_bytes_max = 64 * 1024,
    .list_words_max = 1024,
    .flows_max = 4,
    .flow_parking_bytes_max = 32 * 1024,
    .choice_snapshot_frames_max = 64,
    .choice_snapshot_temps_max = 256,
    .patch_entries_max = 256,
    .observers_max = 16,
    .observer_events_max = 64,
    .errors_max = 8,
    .warnings_max = 8,
    .container_depth_max = 64,
    .load_nodes_max = 4096,
};

test "the sizing example in docs/benchmarks.md" {
    // The documented numbers are the computed ones: the example's main
    // story (default limits, four flows) and side story (small limits), part by part.
    var main: Limits = .{};
    main.flows_max = 4;
    const main_shape: Limits.ProgramShape = .{ .count_slots = 3000, .globals_count = 200 };
    try std.testing.expectEqual(@as(u64, 180_736), main.live_flow_bytes());
    try std.testing.expectEqual(@as(u64, 1_852_800), main.shared_bytes(main_shape));
    try std.testing.expectEqual(@as(u64, 2_230_656), main.bytes_total(main_shape));
    const side = small_story_limits;
    const side_shape: Limits.ProgramShape = .{ .count_slots = 300, .globals_count = 30 };
    try std.testing.expectEqual(@as(u64, 27_776), side.live_flow_bytes());
    try std.testing.expectEqual(@as(u64, 195_120), side.shared_bytes(side_shape));
    try std.testing.expectEqual(@as(u64, 254_768), side.bytes_total(side_shape));
}

test "the budget grows with the program and with every buffer" {
    // Every input moves the budget, so no buffer is left out: grow each limit
    // by one and check that the total grows.
    const base: Limits = .{};
    const shape: Limits.ProgramShape = .{ .count_slots = 0, .globals_count = 0 };
    const base_total = base.bytes_total(shape);
    inline for (@typeInfo(Limits).@"struct".field_names) |name| {
        var grown = base;
        @field(grown, name) += 1;
        const moves = grown.check() == .ok and grown.bytes_total(shape) > base_total;
        const is_count_only = comptime is_not_a_buffer(name);
        try std.testing.expect(moves != is_count_only);
    }
    const bigger: Limits.ProgramShape = .{ .count_slots = 1, .globals_count = 1 };
    try std.testing.expect(base.bytes_total(bigger) > base_total);
}

/// Limits that bound work, not memory, so they don't change the byte budget.
fn is_not_a_buffer(comptime name: []const u8) bool {
    comptime assert(name.len > 0);
    comptime assert(@hasField(Limits, name));
    const names = [_][]const u8{
        "temps_per_frame_max",
        "steps_per_continue_max",
        "evaluate_depth_max",
        "path_components_max",
    };
    inline for (names) |candidate| {
        if (comptime std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

test "fitted limits cover the usage with a margin and stay consistent" {
    // A usage with some zero fields, fitted with margin 2: every buffer
    // holds twice its peak (at least the floor), and the result passes check.
    const usage: Usage = .{
        .evaluation_values = 10,
        .frames = 6,
        .threads = 9,
        .temps = 40,
        .output_items = 30,
        .output_bytes = 20,
        .choices = 4,
        .heap_bytes = 1001,
        .container_depth = 12,
    };
    const limits = fitted(usage, 2);
    try std.testing.expectEqual(Limits.Fault.ok, limits.check());
    try std.testing.expectEqual(@as(u32, 20), limits.evaluation_values_max);
    try std.testing.expectEqual(@as(u32, 18), limits.frames_max); // at least the threads
    try std.testing.expectEqual(@as(u32, 60), limits.output_bytes_max); // at least the items
    try std.testing.expectEqual(@as(u32, 2004), limits.heap_bytes_max); // aligned to 4
    try std.testing.expectEqual(@as(u32, fitted_floor), limits.errors_max);
    try std.testing.expectEqual(@as(u32, 80), limits.temps_per_frame_max); // at most the temps
    const default: Limits = .{};
    try std.testing.expectEqual(default.steps_per_continue_max, limits.steps_per_continue_max);
}
