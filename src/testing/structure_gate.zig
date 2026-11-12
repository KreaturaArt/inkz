//! The structural gate (plan P8.5): every ground-truth case (test/ground_truth, compiled by
//! ink v1.2.1) is compiled from its `.ink` by the new compiler, serialized with
//! ink_json.serialize, and must equal inklecate's `.ink.json` exactly (which covers container
//! names, nesting, flags and every instruction), or be in the divergence ledger (corpus
//! `structure`, engine `new-compiler`). Also the verified pair:
//! load(serialize(compile(source))) is compile(source).

const std = @import("std");
const assert = std.debug.assert;
const oracle = @import("oracle.zig");
const ground_truth_test = @import("ground_truth_test.zig");
const cases = @import("cases.zig");
const compile = @import("../compiler_next/compile.zig");
const ink_json = @import("../core/ink_json.zig");
const Program = @import("../core/program.zig").Program;
const program_testing = @import("../core/program_testing.zig");

pub const engine = "new-compiler";
const file_bytes_max = 16 * 1024 * 1024;

/// The case's `.ink` compiled from its directory (so INCLUDEs resolve as in inklecate).
fn compile_case(arena: std.mem.Allocator, io: std.Io, id: []const u8) !Program {
    assert(id.len > 0);
    assert(id.len > 0);
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
    const options: compile.Options = .{ .count_all_visits = count_all_visits };
    return compile.compile_file_with(arena, io, directory, std.fs.path.basename(path), options);
}

/// Null when the case's serialized program equals inklecate's JSON; otherwise why not.
fn compare_case(arena: std.mem.Allocator, io: std.Io, id: []const u8) !?[]const u8 {
    assert(std.mem.indexOf(u8, id, "..") == null);
    assert(id.len > 0);
    const json_path = try std.fmt.allocPrint(arena, "{s}/{s}.ink.json", .{
        cases.cases_directory,
        id,
    });
    const limit: std.Io.Limit = .limited(file_bytes_max);
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, json_path, arena, limit);
    const bom = "\xEF\xBB\xBF";
    const expected = if (std.mem.startsWith(u8, raw, bom)) raw[bom.len..] else raw;
    var program = compile_case(arena, io, id) catch |err| {
        return try std.fmt.allocPrint(arena, "compile failed: {t}", .{err});
    };
    var out: std.Io.Writer.Allocating = .init(arena);
    try ink_json.serialize(arena, &program, &out.writer);
    const actual = out.written();
    if (std.mem.eql(u8, actual, expected)) return null;
    var at: usize = 0;
    while (at < @min(actual.len, expected.len) and actual[at] == expected[at]) at += 1;
    const from = at -| 24;
    return try std.fmt.allocPrint(arena, "at byte {d}: expected \"{s}\", got \"{s}\"", .{
        at,
        expected[from..@min(expected.len, at + 24)],
        actual[from..@min(actual.len, at + 24)],
    });
}

test "every ground-truth case compiles to inklecate's JSON, or is ledgered" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const ledger = try oracle.read_ledger(arena, io);
    var problems: u32 = 0;
    var compared: u32 = 0;
    for (try ground_truth_test.collect_cases(arena, io)) |id| {
        const json_path = try std.fmt.allocPrint(arena, "{s}/{s}.ink.json", .{
            cases.cases_directory,
            id,
        });
        std.Io.Dir.cwd().access(io, json_path, .{}) catch continue;
        compared += 1;
        const difference = try compare_case(arena, io, id);
        const ledgered = find(ledger, id) != null;
        if (difference != null and !ledgered) {
            std.debug.print("structure: new difference in {s}: {s}\n", .{ id, difference.? });
            problems += 1;
        } else if (difference == null and ledgered) {
            std.debug.print("structure: stale ledger entry: {s} now matches\n", .{id});
            problems += 1;
        }
    }
    assert(compared > 0);
    try std.testing.expectEqual(@as(u32, 0), problems);
}

fn find(ledger: []const oracle.Entry, id: []const u8) ?oracle.Entry {
    assert(ledger.len < std.math.maxInt(u32));
    assert(id.len > 0);
    for (ledger) |entry| {
        if (entry.corpus != .structure or !std.mem.eql(u8, entry.engine, engine)) continue;
        if (std.mem.eql(u8, entry.case, id)) return entry;
    }
    return null;
}

test "the verified pair: loading the serialized program gives the same program" {
    // Goal: P8.5's round trip. Method: for stories covering every kind of content, the
    // program compiled from source equals the one loaded from its serialized JSON.
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
