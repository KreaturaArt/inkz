//! `zig build transcripts`: regenerates `test/transcripts/` from the runtime.

const std = @import("std");
const assert = std.debug.assert;
const transcripts = @import("testing/transcripts.zig");

pub fn main(init: std.process.Init) !void {
    assert(transcripts.actions.len > 0);
    const count = try transcripts.write_all(init.arena.allocator(), init.io);
    assert(count > 0);
    const directory = transcripts.transcripts_directory;
    std.debug.print("wrote {d} transcripts to {s}\n", .{ count, directory });
}
