//! The two oracle gates:
//! - ground truth: each case in `test/ground_truth`, compared with ink v1.2.1;
//! - transcripts: each fixture in `test/transcripts`, compared with the stored transcript.
//! Each story runs in its own process (`src/replay_case.zig`), so a crash is a result.

const std = @import("std");
const oracle = @import("oracle.zig");
const cases = @import("cases.zig");
const isolated = @import("isolated.zig");
const transcripts = @import("transcripts.zig");

const file_bytes_max = 16 * 1024 * 1024;

fn ground_truth_results(arena: std.mem.Allocator, io: std.Io) ![]const oracle.Result {
    const ids = try cases.ids(arena, io);
    const results = try arena.alloc(oracle.Result, ids.len);
    for (ids, results) |id, *result| {
        result.* = .{
            .case = id,
            .expected = try cases.read_expected(arena, io, id),
            .actual = (try isolated.replay(arena, io, &.{id})).transcript,
        };
    }
    return results;
}

fn transcript_results(arena: std.mem.Allocator, io: std.Io) ![]const oracle.Result {
    const ids = try transcripts.collect_fixtures(arena, io);
    const results = try arena.alloc(oracle.Result, ids.len);
    const cwd = std.Io.Dir.cwd();
    for (ids, results) |id, *result| {
        const path = try transcripts.transcript_path(arena, id);
        result.* = .{
            .case = id,
            .expected = try cwd.readFileAlloc(io, path, arena, .limited(file_bytes_max)),
            .actual = try transcripts.render(arena, io, id),
        };
    }
    return results;
}

test "oracle: ground truth" {
    // Goal: every difference from ink is ledgered, and every entry still holds.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const results = try ground_truth_results(arena, std.testing.io);
    try oracle.check(arena, std.testing.io, .ground_truth, results);
}

test "oracle: transcripts" {
    // Goal: every difference from the stored transcripts is ledgered.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const results = try transcript_results(arena, std.testing.io);
    try oracle.check(arena, std.testing.io, .transcripts, results);
}
