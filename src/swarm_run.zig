//! `zig build swarm -Doptimize=ReleaseSafe -- --target <compile|play|save> [--seed S]
//! [--seeds N]`: seeded swarm runs out of the fuzzer (src/testing/swarm_runner.zig). Exits
//! with 1 when a run failed.

const std = @import("std");
const runner = @import("testing/swarm_runner.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(arena);
    var target: runner.Target = .play;
    var seed: u64 = 1;
    var seeds: u32 = 1000;
    var index: usize = 1;
    while (index + 1 < arguments.len) : (index += 2) {
        const name = arguments[index];
        const value = arguments[index + 1];
        if (std.mem.eql(u8, name, "--target")) {
            target = std.meta.stringToEnum(runner.Target, value) orelse return error.UnknownTarget;
        } else if (std.mem.eql(u8, name, "--seed")) {
            seed = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, name, "--seeds")) {
            seeds = try std.fmt.parseInt(u32, value, 10);
        } else return error.UnknownOption;
    }
    var buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(init.io, &buffer);
    const summary = try runner.run(init.gpa, &file_writer.interface, target, seed, seeds);
    try file_writer.interface.flush();
    if (summary.failures > 0) std.process.exit(1);
}
