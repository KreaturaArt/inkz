//! Reports how many runtime tests still reach into the old runtime's internals (plan P0.11),
//! run with `zig build test-inventory`. Such tests can't run against the new engine; they
//! must move to the engine-neutral layer (`src/testing/`) or to ground truth before the old
//! runtime is deleted (P9.1), when the count must be zero.

const std = @import("std");
const assert = std.debug.assert;

/// Files whose tests use the old runtime.
pub const sources = [_][]const u8{
    "src/runtime/callstack.zig", "src/runtime/choices.zig",  "src/runtime/evaluation.zig",
    "src/runtime/json_loader.zig", "src/runtime/lists.zig", "src/runtime/path.zig",
    "src/runtime/pointer.zig",   "src/runtime/state.zig",    "src/runtime/story.zig",
    "src/runtime/value.zig",     "src/runtime/variables.zig", "src/test/helpers.zig",
    "src/ink_format.zig",
};

/// Text that only appears when a test touches internal state or types.
pub const internal_markers = [_][]const u8{
    ".state.",           ".containers",    ".call_stack",   ".variables_state",
    ".evaluation_stack", ".output_stream", ".visit_counts", ".turn_indices",
    ".named_entries",    "path_to_idx",    "RuntimeObject", ".step(",
    "resolvePath",       ".arena",
};

pub const Counts = struct {
    tests_count: u32 = 0,
    internal_count: u32 = 0,
};

/// Counts the `test "..."` blocks in `source` and those that contain an internal marker.
pub fn count_tests(source: []const u8) Counts {
    assert(source.len < 1 << 24);
    var counts: Counts = .{};
    var rest = source;
    while (std.mem.indexOf(u8, rest, "\ntest \"")) |start| {
        const body_start = start + 1;
        const end = std.mem.indexOfPos(u8, rest, body_start, "\n}\n") orelse rest.len;
        counts.tests_count += 1;
        if (uses_internals(rest[body_start..end])) counts.internal_count += 1;
        rest = rest[end..];
    }
    assert(counts.internal_count <= counts.tests_count);
    return counts;
}

fn uses_internals(body: []const u8) bool {
    assert(internal_markers.len > 0);
    for (internal_markers) |marker| {
        assert(marker.len > 0);
        if (std.mem.indexOf(u8, body, marker) != null) return true;
    }
    return false;
}

pub fn main(init: std.process.Init) !void {
    assert(sources.len > 0);
    const io = init.io;
    const arena = init.arena.allocator();
    var total: Counts = .{};
    var buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(io, &buffer);
    const writer = &file_writer.interface;
    for (sources) |path| {
        const source = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 24));
        const counts = count_tests(source);
        total.tests_count += counts.tests_count;
        total.internal_count += counts.internal_count;
        try writer.print("{s}: {d} tests, {d} use internals\n", .{
            path, counts.tests_count, counts.internal_count,
        });
    }
    assert(total.internal_count <= total.tests_count);
    try writer.print("total: {d} old-runtime tests, {d} use internals (target 0 by P9.1)\n", .{
        total.tests_count, total.internal_count,
    });
    try writer.flush();
}

test "count_tests separates public-API tests from internal ones" {
    // Goal: the heuristic itself. Method: one test of each kind.
    const source =
        \\const x = 1;
        \\test "public" {
        \\    _ = try story.cont();
        \\}
        \\test "internal" {
        \\    story.state.story_seed = 3;
        \\}
        \\
    ;
    const counts = count_tests(source);
    try std.testing.expectEqual(@as(u32, 2), counts.tests_count);
    try std.testing.expectEqual(@as(u32, 1), counts.internal_count);
}
