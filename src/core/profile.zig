//! Profile zones (TASK-153): time spent in each stage of the pipeline, for
//! `zig build bench-profile`. A zone is opened at a stage's start and closed at its end:
//!
//!     const zone = profile.begin(.compile_sema);
//!     defer zone.end();
//!
//! Zones nest. Each zone's time is counted inclusive (with the zones inside it) and exclusive
//! (without them), so the exclusive times of a workload add up to the time spent in zones.
//!
//! Profiling is compiled in only when the root source file declares
//! `pub const inkz_profile = true;` (src/bench_profile.zig does). Everywhere else `begin`
//! and `end` are empty and no state exists. With it compiled in, zones record only while
//! `active` is set, so a workload can also be timed without them; `start` must be called
//! first.
//!
//! The clock is the CPU's counter (`cntvct_el0` on aarch64, `rdtsc` on x86_64), cheaper than
//! a system call; `start` measures its rate against `std.Io`'s clock. On Apple silicon it
//! ticks at 24 MHz, so a single zone is only resolved to about 42 ns; totals over many
//! calls average that out.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

pub const enabled = blk: {
    const root = @import("root");
    break :blk @hasDecl(root, "inkz_profile") and root.inkz_profile;
};

pub const Zone = enum(u8) {
    // Compiler.
    compile_comments,
    compile_parse,
    compile_sema,
    compile_resolve,
    compile_lower,
    compile_flatten,
    compile_layout,
    compile_emit,
    // ProgramBuilder.finish (the JSON loader and the compiler's emission).
    builder_resolve_variables,
    builder_resolve_lists,
    builder_layout,
    builder_fixups,
    // ink's JSON.
    json_read_document,
    json_serialize,
    // The program image.
    image_shape,
    image_strings,
    image_arrays,
    image_references,
    image_write,
    program_check,
    // Runtime.
    state_init,
    /// `Story.cont` without the zones inside it: next_line and continue_internal's own work.
    cont,
    reset_globals,
    vm_run,
    after_steps,
    clean_text,
    report_diagnostics,
    notify_observers,
    lookahead_take,
    lookahead_restore,
    choose_choice,
    // Saves.
    save_write,
    load_parse,
    load_validate,
    load_commit,
};

pub const zones_count = @typeInfo(Zone).@"enum".field_names.len;
const depth_max = 64;

/// Per zone, since the last `reset`. Times are in nanoseconds.
pub const Totals = struct {
    calls: [zones_count]u64 = @splat(0),
    inclusive_ns: [zones_count]u64 = @splat(0),
    exclusive_ns: [zones_count]u64 = @splat(0),
};

const Open = struct { zone: Zone, start: u64, children: u64 };

const Recorder = struct {
    /// In ticks until `totals` converts them.
    totals: Totals = .{},
    open: [depth_max]Open = undefined,
    depth: u32 = 0,
    ticks_per_ns: f64 = 0,
};

/// Whether zones record now; change it only with no zone open.
pub var active = false;
var recorder: if (enabled) Recorder else void = if (enabled) .{} else {};

pub const Span = if (enabled) struct {
    recording: bool,

    pub fn end(span: Span) void {
        if (!span.recording) return;
        assert(recorder.depth > 0);
        recorder.depth -= 1;
        const open = recorder.open[recorder.depth];
        const elapsed = ticks() -% open.start;
        assert(elapsed >= open.children);
        const zone = @intFromEnum(open.zone);
        recorder.totals.calls[zone] += 1;
        recorder.totals.inclusive_ns[zone] += elapsed;
        recorder.totals.exclusive_ns[zone] += elapsed - open.children;
        if (recorder.depth > 0) recorder.open[recorder.depth - 1].children += elapsed;
    }
} else struct {
    pub inline fn end(span: Span) void {
        comptime assert(!enabled);
        _ = span;
    }
};

pub inline fn begin(zone: Zone) Span {
    comptime assert(zones_count < 256);
    if (!enabled) return .{};
    if (!active) return .{ .recording = false };
    assert(recorder.depth < depth_max);
    recorder.open[recorder.depth] = .{ .zone = zone, .start = ticks(), .children = 0 };
    recorder.depth += 1;
    return .{ .recording = true };
}

inline fn ticks() u64 {
    comptime assert(enabled);
    switch (builtin.cpu.arch) {
        .aarch64 => return asm volatile ("mrs %[ticks], cntvct_el0"
            : [ticks] "=r" (-> u64),
        ),
        .x86_64 => {
            var low: u32 = undefined;
            var high: u32 = undefined;
            asm volatile ("rdtsc"
                : [low] "={eax}" (low),
                  [high] "={edx}" (high),
            );
            return (@as(u64, high) << 32) | low;
        },
        else => @compileError("profile: no cycle counter for this architecture"),
    }
}

/// Measures the counter's rate against `io`'s clock over `window_ns`; needed before zones
/// record.
pub fn start(io: std.Io, window_ns: u64) void {
    comptime assert(enabled);
    assert(window_ns > 0);
    const clock_start = std.Io.Timestamp.now(io, .awake);
    const ticks_start = ticks();
    var elapsed_ns: i96 = 0;
    while (elapsed_ns < window_ns) {
        elapsed_ns = clock_start.durationTo(std.Io.Timestamp.now(io, .awake)).toNanoseconds();
    }
    const elapsed_ticks: f64 = @floatFromInt(ticks() - ticks_start);
    recorder.ticks_per_ns = elapsed_ticks / @as(f64, @floatFromInt(elapsed_ns));
    assert(recorder.ticks_per_ns > 0);
}

/// The totals since the last `reset`, in nanoseconds; no zone may be open.
pub fn totals() Totals {
    comptime assert(enabled);
    assert(recorder.depth == 0);
    assert(recorder.ticks_per_ns > 0);
    var result = recorder.totals;
    for (&result.inclusive_ns, &result.exclusive_ns) |*inclusive, *exclusive| {
        inclusive.* = to_ns(inclusive.*);
        exclusive.* = to_ns(exclusive.*);
    }
    return result;
}

fn to_ns(count: u64) u64 {
    assert(recorder.ticks_per_ns > 0);
    assert(count < std.math.maxInt(u64));
    return @intFromFloat(@as(f64, @floatFromInt(count)) / recorder.ticks_per_ns);
}

pub fn reset() void {
    comptime assert(enabled);
    assert(recorder.depth == 0);
    recorder.totals = .{};
}

test "without inkz_profile in the root, zones compile to nothing" {
    comptime assert(!enabled);
    const zone = begin(.compile_parse);
    zone.end();
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(Span));
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(@TypeOf(recorder)));
}
