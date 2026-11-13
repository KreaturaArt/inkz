//! Replays one story and prints its transcript, run from the repository root:
//!   `replay_case <case id> [--actions <actions text>]` for a ground-truth case, or
//!   `replay_case --json <story.ink.json> --actions <actions text>`.
//! The gates start it once per story, so a crash is contained in this process.

const std = @import("std");
const cases = @import("testing/cases.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(arena);
    const text = if (arguments.len == 2)
        try cases.replay_case(arena, init.io, arguments[1], null)
    else if (arguments.len == 4 and std.mem.eql(u8, arguments[2], "--actions"))
        try cases.replay_case(arena, init.io, arguments[1], arguments[3])
    else if (arguments.len == 5 and std.mem.eql(u8, arguments[1], "--json") and
        std.mem.eql(u8, arguments[3], "--actions"))
        try cases.replay_json(arena, init.io, arguments[2], arguments[4])
    else {
        std.debug.print("usage: replay_case <case id> [--actions <text>]\n" ++
            "       replay_case --json <story.ink.json> --actions <text>\n", .{});
        std.process.exit(2);
    };
    var buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(init.io, &buffer);
    try file_writer.interface.writeAll(text);
    try file_writer.interface.flush();
}
