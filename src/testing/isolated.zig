//! Runs `replay_case` (src/replay_case.zig) in a child process, so a crashing story is a
//! result rather than the end of the test binary.

const std = @import("std");
const build_options = @import("build_options");

pub const Run = struct {
    /// The transcript; a crashed run's ends with `crash: <how>`.
    transcript: []const u8,
    crashed: bool,
};

/// Runs `replay_case <arguments...>` from the repository root.
pub fn replay(arena: std.mem.Allocator, io: std.Io, arguments: []const []const u8) !Run {
    const argv = try std.mem.concat(arena, []const u8, &.{
        &.{build_options.replay_case_path},
        arguments,
    });
    const result = try std.process.run(arena, io, .{
        .argv = argv,
        .stdout_limit = .limited(16 * 1024 * 1024),
        .stderr_limit = .limited(16 * 1024 * 1024),
    });
    const crashed = switch (result.term) {
        .exited => |code| code != 0,
        else => true,
    };
    if (!crashed) return .{ .transcript = result.stdout, .crashed = false };
    const transcript = try std.fmt.allocPrint(arena, "{s}crash: {any}\n", .{
        result.stdout,
        result.term,
    });
    return .{ .transcript = transcript, .crashed = true };
}
