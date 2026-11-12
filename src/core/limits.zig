//! Limits on everything (plan §3.1). `Story.Options.limits` and `Compiler.Options.limits`
//! override the defaults at runtime; every buffer is sized from them once, at init.
//!
//! `element_bytes` records the planned size of each buffer element. Each real type asserts
//! `@sizeOf(T) == element_bytes.x` at compile time, so `bytes_total` stays exact.

const std = @import("std");
const assert = std.debug.assert;
const fault = @import("fault.zig");

/// Planned element sizes in bytes (plan §4.3, §4.5). Checked by each type's comptime assert.
pub const element_bytes = struct {
    pub const value = 12;
    pub const frame = 24;
    pub const thread = 20; // frame range, counter, previous pointer
    pub const temp = 16; // name: StringId + Value
    pub const output_item = 12;
    pub const string_mark = 4;
    pub const choice = 32;
    pub const tag = 8;
    pub const list_word = 8;
    pub const patch_entry = 16;
    pub const flow = 64; // name, directory ranges into the parking region
    pub const observer = 16;
    pub const observer_event = 4; // GlobalSlot
    pub const diagnostic = 16;
    pub const count_slot = 8; // visit count u32 + turn index i32
    pub const global = value * 2; // current value + default value (§4.10)
    pub const ancestor = 4; // ContainerIndex, for the visit-counting walk (§4.6)
    pub const path_component = 8; // parsed component of a path string (§4.1 path.zig)
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
        // The lookahead snapshot (§4.6) is a second copy of the live-flow buffers.
        const lookahead = live + @as(u64, limits.patch_entries_max) * element_bytes.patch_entry;
        const shared = limits.shared_bytes(shape);
        const total = std.math.add(u64, live, lookahead) catch return null;
        const result = std.math.add(u64, total, shared) catch return null;
        assert(result >= live);
        assert(result >= shared);
        return result;
    }

    /// Buffers that belong to the active flow: call stack, evaluation, output and choices.
    fn live_flow_bytes(limits: *const Limits) u64 {
        const bytes = element_bytes;
        var total: u64 = 0;
        total += @as(u64, limits.evaluation_values_max) * bytes.value;
        total += @as(u64, limits.frames_max) * bytes.frame;
        total += @as(u64, limits.threads_max) * bytes.thread;
        total += @as(u64, limits.temps_max) * bytes.temp;
        total += @as(u64, limits.output_items_max) * bytes.output_item;
        total += limits.output_bytes_max;
        total += @as(u64, limits.string_marks_max) * bytes.string_mark;
        total += @as(u64, limits.choices_max) * bytes.choice;
        total += @as(u64, limits.tags_max) * bytes.tag;
        total += @as(u64, limits.choice_snapshot_frames_max) * bytes.frame;
        total += @as(u64, limits.choice_snapshot_temps_max) * bytes.temp;
        assert(total > limits.output_bytes_max);
        assert(total < std.math.maxInt(u64) / 4);
        return total;
    }

    /// Buffers shared by all flows: globals, counts, the heap, flows and diagnostics.
    fn shared_bytes(limits: *const Limits, shape: ProgramShape) u64 {
        const bytes = element_bytes;
        var total: u64 = 0;
        total += @as(u64, shape.globals_count) * bytes.global;
        total += @as(u64, shape.count_slots) * bytes.count_slot;
        total += limits.heap_bytes_max;
        total += @as(u64, limits.list_words_max) * bytes.list_word;
        total += @as(u64, limits.flows_max) * bytes.flow;
        total += limits.flow_parking_bytes_max;
        total += @as(u64, limits.observers_max) * bytes.observer;
        total += @as(u64, limits.observer_events_max) * bytes.observer_event;
        total += @as(u64, limits.errors_max + limits.warnings_max) * bytes.diagnostic;
        total += @as(u64, limits.container_depth_max) * bytes.ancestor;
        total += @as(u64, limits.path_components_max) * bytes.path_component;
        assert(total >= limits.heap_bytes_max);
        assert(total < std.math.maxInt(u64) / 4);
        return total;
    }
};

/// Bounds for one compilation.
pub const CompilerLimits = struct {
    source_bytes_max: u32 = 16 * 1024 * 1024,
    parse_depth_max: u32 = 256,
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
        // Each retry doubles the workspace (plan T15); more than a few means a sizing bug.
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
    // Goal: the defaults pass their own check. Method: check both limit sets.
    const limits: Limits = .{};
    try std.testing.expectEqual(Limits.Fault.ok, limits.check());
    const compiler: CompilerLimits = .{};
    try std.testing.expectEqual(CompilerLimits.Fault.ok, compiler.check());
}

test "inconsistent limits are rejected by name" {
    // Goal: negative space; each relationship has its own fault. Method: break one at a time.
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
    // Goal: any change to limits or element sizes shows up here and gets a conscious update.
    // Method: compute the budget for the defaults and a small program shape.
    const limits: Limits = .{};
    const shape: Limits.ProgramShape = .{ .count_slots = 100, .globals_count = 20 };
    try std.testing.expectEqual(@as(u64, 1_955_072), limits.bytes_total(shape));
}

test "the budget grows with the program and with every buffer" {
    // Goal: every input moves the budget, so no buffer is left out. Method: grow each limit
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
    };
    inline for (names) |candidate| {
        if (comptime std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}
