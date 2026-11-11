//! Replays one story and prints its transcript (plan P0.3, P0.10), run from the repository
//! root:
//!   `replay_case <engine> <case id>` for a ground-truth case, or
//!   `replay_case <engine> --json <story.ink.json> --actions <actions text>`.
//! The gates start it once per story, so an engine crash is contained in this process.

const std = @import("std");
const assert = std.debug.assert;
const cases = @import("testing/cases.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(arena);
    assert(arguments.len > 0);
    const text = if (arguments.len == 3)
        try cases.replay(arena, init.io, arguments[1], arguments[2])
    else if (arguments.len == 6 and std.mem.eql(u8, arguments[2], "--json") and
        std.mem.eql(u8, arguments[4], "--actions"))
        try cases.replay_json(arena, init.io, arguments[1], arguments[3], arguments[5])
    else {
        std.debug.print("usage: replay_case <engine> <case id>\n" ++
            "       replay_case <engine> --json <story.ink.json> --actions <text>\n", .{});
        std.process.exit(2);
    };
    var buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(init.io, &buffer);
    try file_writer.interface.writeAll(text);
    try file_writer.interface.flush();
    assert(file_writer.interface.end == 0);
}
