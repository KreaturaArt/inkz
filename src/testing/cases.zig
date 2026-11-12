//! Replays one ground-truth case on a named engine (plan P0.10). Shared by the in-process
//! runner `src/replay_case.zig` and kept out of the gate test, which runs each case in a child
//! process so a crashing engine can't take the test binary down with it.

const std = @import("std");
const assert = std.debug.assert;
const transcript = @import("transcript.zig");
const OldEngine = @import("old_engine.zig").OldEngine;
const NewEngine = @import("new_engine.zig").NewEngine;
const old_compiler = @import("../compiler/compiler.zig");

pub const cases_directory = "test/ground_truth";
const file_bytes_max = 16 * 1024 * 1024;

/// Engines the ground-truth gate runs:
/// - `old`: the old runtime on the JSON compiled by ink v1.2.1;
/// - `old_compiler`: the case's `.ink` compiled by the old compiler, on the old runtime.
pub const engines = [_][]const u8{ "old", "old_compiler", "new" };
/// Engines the transcript gate runs; they read the compiled fixtures directly.
pub const transcript_engines = [_][]const u8{ "old", "new" };

/// A case's source: `test/ground_truth/<id>.ink`, or the fixture or story it came from.
pub fn source_path(arena: std.mem.Allocator, io: std.Io, id: []const u8) ![]const u8 {
    assert(id.len > 0);
    const candidates = [_][]const u8{ cases_directory, "test/fixture/original", "test/fixture" };
    for (candidates) |directory| {
        const path = try std.fmt.allocPrint(arena, "{s}/{s}.ink", .{ directory, id });
        std.Io.Dir.cwd().access(io, path, .{}) catch continue;
        assert(std.mem.endsWith(u8, path, ".ink"));
        return path;
    }
    return error.SourceNotFound;
}

/// Replays case `id` on `engine` and returns its transcript. `actions_override` replaces the
/// case's own actions when given.
pub fn replay(
    arena: std.mem.Allocator,
    io: std.Io,
    engine: []const u8,
    id: []const u8,
) ![]const u8 {
    assert(id.len > 0);
    assert(engine.len > 0);
    return replay_with(arena, io, engine, id, null);
}

pub fn replay_with(
    arena: std.mem.Allocator,
    io: std.Io,
    engine: []const u8,
    id: []const u8,
    actions_override: ?[]const u8,
) ![]const u8 {
    assert(id.len > 0);
    assert(engine.len > 0);
    const cwd = std.Io.Dir.cwd();
    const json_path = try std.fmt.allocPrint(arena, "{s}/{s}.ink.json", .{ cases_directory, id });
    const actions_path = try std.fmt.allocPrint(arena, "{s}/{s}.actions", .{ cases_directory, id });
    const actions = actions_override orelse
        cwd.readFileAlloc(io, actions_path, arena, .limited(file_bytes_max)) catch |err|
        switch (err) {
            error.FileNotFound => "play",
            else => return err,
        };
    if (std.mem.eql(u8, engine, "old_compiler")) {
        const source_file = try source_path(arena, io, id);
        const source = try cwd.readFileAlloc(io, source_file, arena, .limited(file_bytes_max));
        const json = old_compiler.compile(arena, source) catch |err| {
            return std.fmt.allocPrint(arena, "exception: \"compile: {t}\"\n", .{err});
        };
        return replay_story(arena, "old", json, actions);
    }
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
    assert(engine.len > 0);
    const json = try std.Io.Dir.cwd().readFileAlloc(io, json_path, arena, .limited(file_bytes_max));
    return replay_story(arena, engine, json, actions);
}

/// Replays `actions` on a story given as JSON text.
fn replay_story(
    arena: std.mem.Allocator,
    engine: []const u8,
    json: []const u8,
    actions: []const u8,
) ![]const u8 {
    assert(json.len > 0);
    if (std.mem.eql(u8, engine, "new")) return replay_new(arena, json, actions);
    if (!std.mem.eql(u8, engine, "old")) return error.UnknownEngine;
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

fn replay_new(arena: std.mem.Allocator, json: []const u8, actions: []const u8) ![]const u8 {
    assert(json.len > 0);
    var output: std.Io.Writer.Allocating = .init(arena);
    var new = NewEngine.open(arena, json) catch |err| {
        try output.writer.print("exception: \"{t}\"\n", .{err});
        return output.written();
    };
    defer new.deinit();
    try transcript.replay(&new, actions, &output.writer);
    assert(output.written().len > 0 or actions.len == 0);
    return output.written();
}
