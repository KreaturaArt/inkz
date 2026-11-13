//! The parser's snapshot corpus: every `test/snapshots/parser/*.ink` is
//! parsed and its tree and diagnostics are checked against the `.snap` next to it
//! (`SNAP_UPDATE=1` rewrites them). A line marked `// inkz-error` (or `// inkz-warning`)
//! must get a diagnostic, and no other line may get one, so the resilience files show that
//! parsing goes on after errors.

const std = @import("std");
const assert = std.debug.assert;
const build_options = @import("build_options");
const snapshot = @import("snapshot");
const grammar = @import("grammar.zig");
const dump = @import("dump.zig");
const lexical = @import("lexical.zig");

const directory_path = "test/snapshots/parser";
const source_bytes_max = 1024 * 1024;
const lines_max = 4096;

test "parser snapshots" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var directory = try std.Io.Dir.cwd().openDir(io, directory_path, .{ .iterate = true });
    defer directory.close(io);
    var iterator = directory.iterate();
    var files: u32 = 0;
    var failures: u32 = 0;
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".ink")) continue;
        files += 1;
        const name = try arena.dupe(u8, entry.name[0 .. entry.name.len - ".ink".len]);
        const source = try directory.readFileAlloc(
            io,
            entry.name,
            arena,
            .limited(source_bytes_max),
        );
        if (!try check_file(arena, io, directory, name, source)) failures += 1;
    }
    assert(files > 0);
    try std.testing.expectEqual(@as(u32, 0), failures);
}

fn check_file(
    arena: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    name: []const u8,
    source: []const u8,
) !bool {
    assert(source.len <= source_bytes_max);
    assert(name.len > 0);
    var parsed = try grammar.parse(std.testing.allocator, source, .{});
    defer parsed.deinit(std.testing.allocator);
    var rendered: std.Io.Writer.Allocating = .init(arena);
    try dump.write(&parsed, &rendered.writer);
    try dump.write_diagnostics(&parsed, &rendered.writer);
    const actual = rendered.written();
    const update = snapshot.update_requested(arena, std.testing.environ, build_options.snap_update);
    const outcome = try snapshot.check(arena, io, directory, name, actual, update);
    var ok = outcome == .matched or outcome == .written;
    if (!ok) try snapshot.report(arena, io, directory, name, actual);
    if (!markers_match(&parsed, source, name)) ok = false;
    return ok;
}

/// Whether the diagnostics fall exactly on the marked lines.
fn markers_match(parsed: *const grammar.Parsed, source: []const u8, name: []const u8) bool {
    // Comment removal keeps the newlines, so line numbers agree.
    assert(std.mem.count(u8, parsed.source, "\n") == std.mem.count(u8, source, "\n"));
    var diagnosed: [lines_max]bool = @splat(false);
    for (parsed.diagnostics()) |diagnostic| {
        const line = lexical.line_and_column(parsed.source, diagnostic.offset).line;
        assert(line <= lines_max);
        diagnosed[line - 1] = true;
    }
    var lines = std.mem.splitScalar(u8, source, '\n');
    var number: u32 = 1;
    var ok = true;
    while (lines.next()) |line| : (number += 1) {
        const marked = std.mem.indexOf(u8, line, "// inkz-error") != null or
            std.mem.indexOf(u8, line, "// inkz-warning") != null;
        if (marked != diagnosed[number - 1]) {
            const what = if (marked) "has no diagnostic" else "has an unexpected diagnostic";
            std.debug.print("{s}.ink:{d}: line {s}\n", .{ name, number, what });
            ok = false;
        }
    }
    return ok;
}
