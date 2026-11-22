//! The differential swarm run (src/testing/differential.zig), commands of src/dev.zig:
//!   `swarm-gen --seed <s> --count <n> --out <dir> [--swarm <line>]`:
//!   generated cases, each with its drawn configuration or the one given;
//!   `swarm-check <dir>`: compares inkz with ink's results, which
//!   `mise run reference:swarm -- <dir>` writes; exits 1 on a divergence;
//!   `swarm-reduce <dir> <case> --harness <ink_harness.dll>`: drops swarm
//!   features while the case's divergence stays, running ink's harness for each candidate.
//! `zig build swarm-gen`, `swarm-check` and `swarm-reduce` run them.

const std = @import("std");
const assert = std.debug.assert;
const differential = @import("testing/differential.zig");
const isolated = @import("testing/isolated.zig");
const fuzz_ink = @import("testing/fuzz_ink.zig");
const Swarm = fuzz_ink.Swarm;

const usage =
    \\usage: dev swarm-gen --seed <s> --count <n> --out <dir> [--swarm <line>]
    \\       dev swarm-check <dir>
    \\       dev swarm-reduce <dir> <case> --harness <ink_harness.dll>
    \\
;

/// `arguments[0]` is the command's name (src/dev.zig).
pub fn command(arena: std.mem.Allocator, io: std.Io, arguments: []const [:0]const u8) !void {
    const gen = arguments.len >= 7 and std.mem.eql(u8, arguments[0], "swarm-gen") and
        std.mem.eql(u8, arguments[1], "--seed") and std.mem.eql(u8, arguments[3], "--count") and
        std.mem.eql(u8, arguments[5], "--out");
    const swarm_given = arguments.len == 9 and std.mem.eql(u8, arguments[7], "--swarm");
    if (gen and (arguments.len == 7 or swarm_given)) {
        const seed = try std.fmt.parseInt(u64, arguments[2], 10);
        const count = try std.fmt.parseInt(u32, arguments[4], 10);
        const swarm: ?Swarm = if (swarm_given) try Swarm.parse(arguments[8]) else null;
        try std.Io.Dir.cwd().createDirPath(io, arguments[6]);
        var directory = try std.Io.Dir.cwd().openDir(io, arguments[6], .{});
        defer directory.close(io);
        try differential.generate(io, directory, seed, count, swarm);
        std.debug.print("{d} cases in {s}\n", .{ count, arguments[6] });
        return;
    }
    if (arguments.len == 2 and std.mem.eql(u8, arguments[0], "swarm-check")) {
        var buffer: [4096]u8 = undefined;
        var file_writer = std.Io.File.stdout().writer(io, &buffer);
        const writer = &file_writer.interface;
        const summary = try differential.check_directory(arena, io, arguments[1], replay, writer);
        try writer.flush();
        if (summary.divergences() > 0) std.process.exit(1);
        return;
    }
    if (arguments.len == 5 and std.mem.eql(u8, arguments[0], "swarm-reduce") and
        std.mem.eql(u8, arguments[3], "--harness"))
    {
        return reduce(arena, io, arguments[1], arguments[2], arguments[4]);
    }
    std.debug.print("{s}", .{usage});
    std.process.exit(2);
}

/// Each replay in its own process, so a crash is a result.
fn replay(
    arena: std.mem.Allocator,
    io: std.Io,
    json_path: []const u8,
    actions: []const u8,
) anyerror![]const u8 {
    const run = try isolated.replay(arena, io, &.{ "--json", json_path, "--actions", actions });
    return run.transcript;
}

/// What a divergence is, so a reduction keeps the same one.
const Class = enum { acceptance, runtime, pipeline, structure };

fn class_of(verdict: differential.Verdict) ?Class {
    if (verdict.acceptance != null) return .acceptance;
    if (verdict.runtime != null) return .runtime;
    if (verdict.pipeline != null) return .pipeline;
    if (verdict.structure) return .structure;
    return null;
}

/// The reducer's oracle: each candidate is generated from the case's seed into its own
/// directory, run by ink's harness, and checked.
const Oracle = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    directory_path: []const u8,
    harness: []const u8,
    seed: u64,
    class: Class,
    calls: u32 = 0,

    pub fn diverges(oracle: *Oracle, candidate: Swarm) !bool {
        oracle.calls += 1;
        var swarm = candidate;
        swarm.normalize();
        const path = try std.fmt.allocPrint(oracle.arena, "{s}/{d:0>3}", .{
            oracle.directory_path,
            oracle.calls,
        });
        try std.Io.Dir.cwd().createDirPath(oracle.io, path);
        var directory = try std.Io.Dir.cwd().openDir(oracle.io, path, .{});
        defer directory.close(oracle.io);
        _ = try differential.write_case(oracle.io, directory, "case", oracle.seed, swarm);
        // The harness exits 3 when it has to give up on loops; it skips finished cases.
        while (true) {
            const result = try std.process.run(oracle.arena, oracle.io, .{
                .argv = &.{ "dotnet", oracle.harness, "batch", path },
            });
            switch (result.term) {
                .exited => |code| if (code == 3) continue else if (code == 0) break,
                else => {},
            }
            return error.HarnessFailed;
        }
        const verdict = try differential.check_case(
            oracle.arena,
            oracle.io,
            directory,
            path,
            "case",
            replay,
        );
        return class_of(verdict) == oracle.class;
    }
};

fn reduce(
    arena: std.mem.Allocator,
    io: std.Io,
    directory_path: []const u8,
    name: []const u8,
    harness: []const u8,
) !void {
    var directory = try std.Io.Dir.cwd().openDir(io, directory_path, .{});
    defer directory.close(io);
    const swarm_path = try std.fmt.allocPrint(arena, "{s}.swarm", .{name});
    const text = try directory.readFileAlloc(io, swarm_path, arena, .limited(4096));
    var lines = std.mem.splitScalar(u8, text, '\n');
    const start = try Swarm.parse(lines.next() orelse return error.BadSwarmFile);
    const seed_line = lines.next() orelse return error.BadSwarmFile;
    if (!std.mem.startsWith(u8, seed_line, "seed ")) return error.BadSwarmFile;
    const seed = try std.fmt.parseInt(u64, seed_line["seed ".len..], 10);
    const verdict = try differential.check_case(arena, io, directory, directory_path, name, replay);
    const class = class_of(verdict) orelse {
        std.debug.print("{s} doesn't diverge\n", .{name});
        return;
    };
    var oracle: Oracle = .{
        .arena = arena,
        .io = io,
        .directory_path = try std.fmt.allocPrint(arena, "{s}/reduce-{s}", .{
            directory_path,
            name,
        }),
        .harness = harness,
        .seed = seed,
        .class = class,
    };
    const reduction = try differential.reduce(start, &oracle);
    var reduced = reduction.swarm;
    reduced.normalize();
    assert(reduced.valid());
    std.debug.print("{t} divergence, {d} oracle calls; reduced swarm:\n{f}\n", .{
        class,
        reduction.calls,
        reduced,
    });
    std.debug.print("the last diverging candidate is under {s}\n", .{oracle.directory_path});
}
