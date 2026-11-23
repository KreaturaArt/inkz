//! The structural gate: every ground-truth case (test/ground_truth, compiled by
//! ink v1.2.1) is compiled from its `.ink` by the compiler, serialized with
//! ink_json.serialize, and must equal inklecate's `.ink.json` exactly (which covers container
//! names, nesting, flags and every instruction), and loading that JSON must give the compiled
//! program back (the verified pair: load(serialize(compile(source))) is compile(source)). So
//! the ground-truth gate, which plays inklecate's JSON, also plays what the compiler makes.

const std = @import("std");
const assert = std.debug.assert;
const cases = @import("cases.zig");
const compile = @import("../compiler/compile.zig");
const ink_json = @import("../core/ink_json.zig");
const Program = @import("../core/program.zig").Program;
const program_testing = @import("../core/program_testing.zig");

/// The case's `.ink` compiled from its directory (so INCLUDEs resolve as in inklecate).
fn compile_case(arena: std.mem.Allocator, io: std.Io, id: []const u8) !Program {
    return compile_case_with(arena, io, id, null);
}

fn compile_case_with(
    arena: std.mem.Allocator,
    io: std.Io,
    id: []const u8,
    statistics: ?*compile.Statistics,
) !Program {
    const path = try cases.source_path(arena, io, id);
    const directory_path = std.fs.path.dirname(path) orelse ".";
    var directory = try std.Io.Dir.cwd().openDir(io, directory_path, .{});
    defer directory.close(io);
    // A case compiled with ink's countAllVisits option says so with a marker file.
    const marker = try std.fmt.allocPrint(arena, "{s}/{s}.count_all_visits", .{
        cases.cases_directory,
        id,
    });
    const count_all_visits = if (std.Io.Dir.cwd().access(io, marker, .{})) true else |_| false;
    const options: compile.Options = .{
        .count_all_visits = count_all_visits,
        .statistics = statistics,
    };
    return compile.compile_file_with(arena, io, directory, std.fs.path.basename(path), options);
}

/// Null when the case's serialized program equals inklecate's JSON and loads back as the
/// same program; otherwise why not.
fn compare_case(arena: std.mem.Allocator, io: std.Io, id: []const u8) !?[]const u8 {
    assert(std.mem.indexOf(u8, id, "..") == null);
    const raw = try cases.read_json(arena, io, id);
    const bom = "\xEF\xBB\xBF";
    const expected = if (std.mem.startsWith(u8, raw, bom)) raw[bom.len..] else raw;
    var program = compile_case(arena, io, id) catch |err| {
        return try std.fmt.allocPrint(arena, "compile failed: {t}", .{err});
    };
    var out: std.Io.Writer.Allocating = .init(arena);
    try ink_json.serialize(arena, &program, &out.writer);
    const actual = out.written();
    if (std.mem.eql(u8, actual, expected)) {
        var loaded = try ink_json.load(arena, actual);
        program_testing.expect_same_program(&program, &loaded) catch |err| {
            return try std.fmt.allocPrint(arena, "the loaded JSON differs: {t}", .{err});
        };
        return null;
    }
    var at: usize = 0;
    while (at < @min(actual.len, expected.len) and actual[at] == expected[at]) at += 1;
    const from = at -| 24;
    return try std.fmt.allocPrint(arena, "at byte {d}: expected \"{s}\", got \"{s}\"", .{
        at,
        expected[from..@min(expected.len, at + 24)],
        actual[from..@min(actual.len, at + 24)],
    });
}

test "every ground-truth case compiles to inklecate's JSON and loads back the same" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var problems: u32 = 0;
    var compared: u32 = 0;
    for (try cases.ids(arena, io)) |id| {
        compared += 1;
        const difference = try compare_case(arena, io, id);
        if (difference) |text| {
            std.debug.print("structure: difference in {s}: {s}\n", .{ id, text });
            problems += 1;
        }
    }
    assert(compared > 0);
    try std.testing.expectEqual(@as(u32, 0), problems);
}

test "the verified pair: loading the serialized program gives the same program" {
    // The image round trip on small stories covering every kind of content; the gate
    // above checks it for every ground-truth case, crime_scene.ink and
    // simple_taster_tutorial.ink among them.
    const gpa = std.testing.allocator;
    const sources = [_][]const u8{
        "Hello.\n* [A] -> k\n* B\n- (g) {g} -> k\n== k ==\n{&a|b} {x: y|z}\n-> DONE\nVAR x = 1\n",
        "LIST l = a, (b)\nVAR v = (a)\n{v} {l(1)} {LIST_COUNT(l)} {a}\n-> t ->\n" ++
            "== t ==\n<- th\n->->\n== th ==\n* c\n-> DONE\n",
        "~ temp r = f(2)\n{r}\n== function f(n) ==\n{ n:\n- 1: one\n- else: other\n}\n" ++
            "~ return n * 1.5\n",
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

test "program equality names an array that differs in one element" {
    // P18.4: the check the swarm's round trips use looks at every array, not only lengths.
    const gpa = std.testing.allocator;
    var compiled = try compile.compile_source(gpa, "VAR x = 1\n== k ==\n{x} -> DONE\n");
    defer compiled.deinit(gpa);
    try std.testing.expect(program_testing.first_difference(&compiled, &compiled) == null);

    var globals = try gpa.dupe(@TypeOf(compiled.globals[0]), compiled.globals);
    defer gpa.free(globals);
    try std.testing.expectEqual(@as(usize, 1), globals.len);
    globals[0].name = compiled.newline;
    var other = compiled;
    other.globals = globals;
    const globals_differ = program_testing.first_difference(&compiled, &other).?;
    try std.testing.expectEqualStrings("globals", globals_differ);

    var named = try gpa.dupe(@TypeOf(compiled.named[0]), compiled.named);
    defer gpa.free(named);
    try std.testing.expect(named.len > 0);
    named[named.len - 1].name = compiled.newline;
    other = compiled;
    other.named = named;
    const named_differ = program_testing.first_difference(&compiled, &other).?;
    try std.testing.expectEqualStrings("named", named_differ);
}

test "every ground-truth story compiles without a workspace retry" {
    // The workspace estimate covers the corpus: a retry is a whole second parse (F14,
    // P16.17); "a source denser than the workspace estimate retries" shows the other side.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var compiled: u32 = 0;
    for (try cases.ids(arena, io)) |id| {
        _ = cases.source_path(arena, io, id) catch continue;
        var statistics: compile.Statistics = .{};
        _ = compile_case_with(arena, io, id, &statistics) catch continue;
        if (statistics.workspace_retries != 0) {
            std.debug.print("{s}: {d} workspace retries\n", .{ id, statistics.workspace_retries });
            return error.WorkspaceRetried;
        }
        compiled += 1;
    }
    try std.testing.expect(compiled > 150);
}
