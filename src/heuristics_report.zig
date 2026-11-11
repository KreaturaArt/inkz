//! `zig build heuristics-report` (plan P0.12): counts how often the old runtime's weave
//! heuristics (`loopBackGatherTailPeel`, `divertTargetsAncestorOfAnyChoiceSource`) change
//! control flow on each ground-truth case, separately for ink's compiler (engine `old`) and
//! the old compiler (`old_compiler`). P5.2 uses the report to tell real runtime gaps from
//! compensation for old-compiler output. Each case runs with its own actions and with three
//! seeded random choice policies. The table goes into docs/benchmarks.md between markers.

const std = @import("std");
const assert = std.debug.assert;
const build_options = @import("build_options");
const ground_truth = @import("testing/ground_truth_test.zig");

const report_path = "docs/benchmarks.md";
const start_marker = "<!-- heuristics:start -->";
const end_marker = "<!-- heuristics:end -->";

const Counts = struct {
    loop_back: u32 = 0,
    divert_ancestor: u32 = 0,

    fn any(counts: Counts) bool {
        assert(counts.loop_back < std.math.maxInt(u32));
        const total = @as(u64, counts.loop_back) + counts.divert_ancestor;
        assert(total <= 2 * @as(u64, std.math.maxInt(u32)));
        return total > 0;
    }
};

/// The case's own actions, then seeded random choices, so weave paths off the first choice
/// are covered too.
const policies = [_]?[]const u8{ null, "play_seeded 1", "play_seeded 2", "play_seeded 3" };

/// Runs case `id` on `engine` with every policy and adds up the counts.
fn measure(arena: std.mem.Allocator, io: std.Io, engine: []const u8, id: []const u8) !Counts {
    assert(id.len > 0);
    var total: Counts = .{};
    for (policies) |policy| {
        const counts = try measure_once(arena, io, engine, id, policy);
        total.loop_back += counts.loop_back;
        total.divert_ancestor += counts.divert_ancestor;
    }
    assert(total.loop_back < std.math.maxInt(u32));
    return total;
}

/// Runs case `id` on `engine` in a child process and reads the counts from its stderr.
fn measure_once(
    arena: std.mem.Allocator,
    io: std.Io,
    engine: []const u8,
    id: []const u8,
    policy: ?[]const u8,
) !Counts {
    assert(id.len > 0);
    const replay_case = build_options.replay_case_path;
    const argv: []const []const u8 = if (policy) |actions|
        &.{ replay_case, engine, id, "--actions", actions }
    else
        &.{ replay_case, engine, id };
    const result = try std.process.run(arena, io, .{
        .argv = argv,
        .stdout_limit = .limited(16 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    const line_start = std.mem.lastIndexOf(u8, result.stderr, "heuristics: ") orelse return .{};
    var words = std.mem.tokenizeAny(u8, result.stderr[line_start..], " =\n");
    _ = words.next();
    var counts: Counts = .{};
    while (words.next()) |name| {
        const value = try std.fmt.parseInt(u32, words.next() orelse break, 10);
        if (std.mem.eql(u8, name, "loop_back_gather_tail")) counts.loop_back = value;
        const is_divert = std.mem.eql(u8, name, "divert_ancestor_of_choice_source");
        if (is_divert) counts.divert_ancestor = value;
    }
    assert(counts.loop_back < std.math.maxInt(u32));
    return counts;
}

pub fn main(init: std.process.Init) !void {
    assert(policies.len > 0);
    const arena = init.arena.allocator();
    const io = init.io;
    const ids = try ground_truth.collect_cases(arena, io);
    var table: std.Io.Writer.Allocating = .init(arena);
    const writer = &table.writer;
    try writer.writeAll(start_marker ++ "\n" ++
        "| Case | ink compiler: loop-back peel | ink compiler: divert to ancestor | " ++
        "old compiler: loop-back peel | old compiler: divert to ancestor |\n" ++
        "|---|---|---|---|---|\n");
    var rows: u32 = 0;
    for (ids) |id| {
        const ink = try measure(arena, io, "old", id);
        const old = try measure(arena, io, "old_compiler", id);
        if (!ink.any() and !old.any()) continue;
        try writer.print("| `{s}` | {d} | {d} | {d} | {d} |\n", .{
            id, ink.loop_back, ink.divert_ancestor, old.loop_back, old.divert_ancestor,
        });
        rows += 1;
    }
    try writer.print("\n{d} of {d} cases fire a heuristic.\n" ++ end_marker ++ "\n", .{
        rows, ids.len,
    });
    try write_section(arena, io, table.written());
    assert(rows <= ids.len);
    std.debug.print("heuristics fire on {d} of {d} cases; written to {s}\n", .{
        rows, ids.len, report_path,
    });
}

/// Replaces the marked section of the report, or appends it.
fn write_section(arena: std.mem.Allocator, io: std.Io, section: []const u8) !void {
    assert(std.mem.startsWith(u8, section, start_marker));
    const cwd = std.Io.Dir.cwd();
    const existing = cwd.readFileAlloc(io, report_path, arena, .limited(1 << 22)) catch "";
    const start = std.mem.indexOf(u8, existing, start_marker);
    const end = std.mem.indexOf(u8, existing, end_marker);
    const text = if (start != null and end != null)
        try std.mem.concat(arena, u8, &.{
            existing[0..start.?],
            section,
            existing[end.? + end_marker.len + 1 ..],
        })
    else
        try std.mem.concat(arena, u8, &.{ existing, section });
    assert(text.len >= section.len);
    try cwd.writeFile(io, .{ .sub_path = report_path, .data = text });
}
