//! The lowering's layout against inklecate (plan P8.4): each `test/lowering/<name>.ink` must
//! compile to exactly the JSON inklecate wrote for it (`<name>.json`, made with the .NET
//! harness: `dotnet reference/ink_harness_build/ink_harness.dll compile in.ink out.json`).

const std = @import("std");
const assert = std.debug.assert;
const compile = @import("compile.zig");
const ink_json = @import("../core/ink_json.zig");
const program_testing = @import("../core/program_testing.zig");

const directory_path = "test/lowering";
const file_bytes_max = 4 * 1024 * 1024;

test "lowering matches inklecate's JSON" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var directory = try std.Io.Dir.cwd().openDir(io, directory_path, .{ .iterate = true });
    defer directory.close(io);
    var iterator = directory.iterate();
    var failures: u32 = 0;
    var cases: u32 = 0;
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".ink")) continue;
        cases += 1;
        const limit: std.Io.Limit = .limited(file_bytes_max);
        const source = try directory.readFileAlloc(io, entry.name, arena, limit);
        const json_name = try std.fmt.allocPrint(
            arena,
            "{s}.json",
            .{entry.name[0 .. entry.name.len - 4]},
        );
        const expected_raw = try directory.readFileAlloc(io, json_name, arena, limit);
        const bom = "\xEF\xBB\xBF";
        const has_bom = std.mem.startsWith(u8, expected_raw, bom);
        const expected = if (has_bom) expected_raw[bom.len..] else expected_raw;
        if (!try matches(gpa, entry.name, source, expected)) failures += 1;
    }
    assert(cases > 0);
    try std.testing.expectEqual(@as(u32, 0), failures);
}

fn matches(
    gpa: std.mem.Allocator,
    name: []const u8,
    source: []const u8,
    expected: []const u8,
) !bool {
    assert(expected.len > 0);
    assert(name.len > 0);
    const actual = compile.compile_to_json(gpa, source) catch |err| {
        std.debug.print("{s}: {t}\n", .{ name, err });
        return false;
    };
    defer gpa.free(actual);
    if (std.mem.eql(u8, actual, expected)) return true;
    var at: usize = 0;
    while (at < @min(actual.len, expected.len) and actual[at] == expected[at]) at += 1;
    const from = at -| 80;
    std.debug.print("{s}: differs at {d}\n  expected: ...{s}\n  actual:   ...{s}\n", .{
        name,
        at,
        expected[from..@min(expected.len, at + 80)],
        actual[from..@min(actual.len, at + 80)],
    });
    return false;
}

test "keyed targets name the containers their JSON paths name" {
    // The emission gives the builder its targets as keys, not paths. Method: each program's
    // JSON, loaded back (resolving every path with ink's rules), gives the same program, so
    // every divert, choice, read count and divert target points where its path does.
    const gpa = std.testing.allocator;
    const sources = [_][]const u8{
        "-> k.s\n== k ==\n= s\n{k.s} {-> k} -> t ->\n-> DONE\n== t ==\n->->\n",
        "* (c) A\n* B -> g\n- (g) {c: x} {!y|z} {TURNS_SINCE(-> g)}\n-> END\n",
        "{ 1 > 0:\n  - a\n  -> h\n- else: b\n}\n- (h) c\n~ temp d = -> h\n-> d\n",
    };
    for (sources) |source| {
        var compiled = try compile.compile_source(gpa, source);
        defer compiled.deinit(gpa);
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try ink_json.serialize(gpa, &compiled, &out.writer);
        var loaded = try ink_json.load(gpa, out.written());
        defer loaded.deinit(gpa);
        try program_testing.expect_same_program(&compiled, &loaded);
    }
}
