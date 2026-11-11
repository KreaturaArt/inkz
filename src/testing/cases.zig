//! Replays one ground-truth case on a named engine (plan P0.10). Shared by the in-process
//! runner `src/replay_case.zig` and kept out of the gate test, which runs each case in a child
//! process so a crashing engine can't take the test binary down with it.

const std = @import("std");
const assert = std.debug.assert;
const transcript = @import("transcript.zig");
const OldEngine = @import("old_engine.zig").OldEngine;

pub const cases_directory = "test/ground_truth";
const file_bytes_max = 16 * 1024 * 1024;

pub const engines = [_][]const u8{"old"};

/// Replays case `id` on `engine` and returns its transcript.
pub fn replay(
    arena: std.mem.Allocator,
    io: std.Io,
    engine: []const u8,
    id: []const u8,
) ![]const u8 {
    assert(id.len > 0);
    assert(engine.len > 0);
    const cwd = std.Io.Dir.cwd();
    const json_path = try std.fmt.allocPrint(arena, "{s}/{s}.ink.json", .{ cases_directory, id });
    const actions_path = try std.fmt.allocPrint(arena, "{s}/{s}.actions", .{ cases_directory, id });
    const actions = cwd.readFileAlloc(io, actions_path, arena, .limited(file_bytes_max)) catch |err|
        switch (err) {
            error.FileNotFound => "play",
            else => return err,
        };
    return replay_json(arena, io, engine, json_path, actions);
}

/// Replays `actions` on the story at `json_path` with `engine` and returns the transcript.
pub fn replay_json(
    arena: std.mem.Allocator,
    io: std.Io,
    engine: []const u8,
    json_path: []const u8,
    actions: []const u8,
) ![]const u8 {
    assert(json_path.len > 0);
    if (!std.mem.eql(u8, engine, "old")) return error.UnknownEngine;
    const json = try std.Io.Dir.cwd().readFileAlloc(io, json_path, arena, .limited(file_bytes_max));
    var output: std.Io.Writer.Allocating = .init(arena);
    var old = OldEngine.init(arena, json) catch |err| {
        try output.writer.print("exception: \"{t}\"\n", .{err});
        return output.written();
    };
    defer old.deinit();
    try transcript.replay(&old, actions, &output.writer);
    assert(output.written().len > 0 or actions.len == 0);
    return output.written();
}
