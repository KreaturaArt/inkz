//! Checks that the CI workflow, the `ci` build step and the pinned toolchain agree.

const std = @import("std");
const assert = std.debug.assert;

const workflow_path = ".github/workflows/ci.yml";

fn read(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    assert(path.len > 0);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .limited(1 << 20));
    assert(bytes.len <= 1 << 20);
    return bytes;
}

/// The value after `key` on the first line that starts with it (after indentation), with
/// quotes trimmed.
fn value_after(text: []const u8, key: []const u8) ?[]const u8 {
    assert(key.len > 0);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, key)) continue;
        const value = std.mem.trim(u8, trimmed[key.len..], " \t\"'");
        assert(value.len <= trimmed.len);
        return value;
    }
    return null;
}

test "the CI workflow pins the Zig version mise.toml pins" {
    const gpa = std.testing.allocator;
    const workflow = try read(gpa, workflow_path);
    defer gpa.free(workflow);
    const mise = try read(gpa, "mise.toml");
    defer gpa.free(mise);

    const pinned = value_after(mise, "zig =") orelse return error.NoZigInMise;
    const used = value_after(workflow, "version:") orelse return error.NoZigInWorkflow;
    try std.testing.expectEqualStrings(pinned, used);
}

test "the CI workflow runs zig build ci, and build.zig defines it over fmt, lint, test and fuzz" {
    const gpa = std.testing.allocator;
    const workflow = try read(gpa, workflow_path);
    defer gpa.free(workflow);
    const build = try read(gpa, "build.zig");
    defer gpa.free(build);

    try std.testing.expect(std.mem.indexOf(u8, workflow, "run: zig build ci") != null);
    try std.testing.expect(std.mem.indexOf(u8, build, "b.step(\"ci\"") != null);
    const dependencies = [_][]const u8{ "&fmt.step", "&run_lint.step", "test_all", "fuzz_corpus" };
    for (dependencies) |dependency| {
        const line = try std.fmt.allocPrint(gpa, "ci_step.dependOn({s});", .{dependency});
        defer gpa.free(line);
        try std.testing.expect(std.mem.indexOf(u8, build, line) != null);
    }
}

test "value_after reads a key's value and skips lines without it" {
    const text = "[tools]\n  dotnet = \"8\"\n  zig = \"0.17.1\"\n";
    try std.testing.expectEqualStrings("0.17.1", value_after(text, "zig =").?);
    try std.testing.expect(value_after(text, "python =") == null);
}
