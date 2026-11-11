//! Replays one ground-truth case and prints its transcript (plan P0.10):
//! `replay_case <engine> <case id>`, run from the repository root. The ground-truth gate
//! starts it once per case, so an engine crash is contained in this process.

const std = @import("std");
const assert = std.debug.assert;
const cases = @import("testing/cases.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(arena);
    assert(arguments.len > 0);
    if (arguments.len != 3) {
        std.debug.print("usage: replay_case <engine> <case id>\n", .{});
        std.process.exit(2);
    }
    const text = try cases.replay(arena, init.io, arguments[1], arguments[2]);
    var buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(init.io, &buffer);
    try file_writer.interface.writeAll(text);
    try file_writer.interface.flush();
    assert(file_writer.interface.end == 0);
}
