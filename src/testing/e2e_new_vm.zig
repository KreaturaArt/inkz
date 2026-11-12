//! The old compiler's e2e tests on the new VM (plan P8.0): each story the e2e helpers play on
//! the old runtime is also compiled by the old front end into a Program
//! (src/compiler/codegen_to_program.zig) and played on the new VM with the same choices. The
//! two outputs must agree, or the case must be in the divergence ledger (corpus `e2e`,
//! engine `old-compiler`) with what ink itself prints for it.

const std = @import("std");
const assert = std.debug.assert;
const oracle = @import("oracle.zig");
const codegen_to_program = @import("../compiler/codegen_to_program.zig");
const vm = @import("../vm/api.zig");
const Severity = @import("../vm/state.zig").Diagnostic.Severity;

pub const engine = "old-compiler";
const steps_max = 100_000;
const case_bytes_max = 160;

/// A ledger key for a case: the fixture path, or a hash of an inline source.
pub fn case_name(buffer: *[case_bytes_max]u8, fixture: ?[]const u8, source: []const u8) []const u8 {
    assert(source.len < std.math.maxInt(u32));
    if (fixture) |path| {
        assert(path.len + 4 <= buffer.len);
        return std.fmt.bufPrint(buffer, "e2e/{s}", .{path}) catch unreachable;
    }
    const hash = std.hash.Fnv1a_32.hash(source);
    const name = std.fmt.bufPrint(buffer, "e2e/inline/{x:0>8}", .{hash}) catch unreachable;
    assert(name.len > 0);
    return name;
}

fn ignore_error(_: ?*anyopaque, _: []const u8, _: Severity) void {}

/// Plays `source` through `choices` on the new VM (choosing when it can't continue, as the
/// old helpers do). Runtime errors don't stop it, as they don't on the old runtime.
pub fn play(gpa: std.mem.Allocator, source: []const u8, choices: []const usize) ![]u8 {
    assert(source.len < std.math.maxInt(u32));
    var program = try codegen_to_program.compile(gpa, source);
    defer program.deinit(gpa);
    var story: vm.Story = undefined;
    try story.init(gpa, &program, .{ .on_error = ignore_error });
    defer story.deinit(gpa);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);
    var chosen: usize = 0;
    for (0..steps_max) |_| {
        const waiting = story.current_choices_count() > 0 and !story.can_continue();
        if (waiting and chosen < choices.len) {
            try story.choose_choice_index(@intCast(choices[chosen]));
            chosen += 1;
            continue;
        }
        if (!story.can_continue()) break;
        const line = try story.cont_alloc(gpa);
        defer gpa.free(line);
        try output.appendSlice(gpa, line);
    }
    assert(chosen <= choices.len);
    return output.toOwnedSlice(gpa);
}

/// Plays the case on the new VM and checks it against `old_output` and the ledger.
pub fn check(
    gpa: std.mem.Allocator,
    fixture: ?[]const u8,
    source: []const u8,
    choices: []const usize,
    old_output: []const u8,
) !void {
    assert(source.len < std.math.maxInt(u32));
    assert(old_output.len < std.math.maxInt(u32));
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var name_buffer: [case_bytes_max]u8 = undefined;
    const case = case_name(&name_buffer, fixture, source);
    const new_output = play(arena, source, choices) catch |err| @errorName(err);
    const differs = !std.mem.eql(u8, new_output, old_output);
    const entry = find(try oracle.read_ledger(arena, std.testing.io), case);
    if (differs and entry == null) {
        std.debug.print("new e2e divergence; add to test/divergence_ledger.zon:\n" ++
            "    .{{ .case = \"{s}\", .engine = \"{s}\", .corpus = .e2e, .kind = .other, " ++
            ".reason = \"old: {f}, new: {f}\" }},\n", .{
            case,
            engine,
            std.zig.fmtString(old_output[0..@min(old_output.len, 60)]),
            std.zig.fmtString(new_output[0..@min(new_output.len, 60)]),
        });
        return error.NewDivergence;
    }
    if (!differs and entry != null) {
        std.debug.print("stale e2e ledger entry: {s} now agrees\n", .{case});
        return error.StaleLedgerEntry;
    }
    assert(differs == (entry != null));
}

fn find(ledger: []const oracle.Entry, case: []const u8) ?oracle.Entry {
    assert(case.len > 0);
    for (ledger) |entry| {
        if (entry.corpus != .e2e or !std.mem.eql(u8, entry.engine, engine)) continue;
        if (std.mem.eql(u8, entry.case, case)) return entry;
    }
    assert(ledger.len < std.math.maxInt(u32));
    return null;
}

test "case_name keys fixtures by path and inline sources by hash" {
    // Goal: stable ledger keys. Method: a fixture path, and the same inline source twice.
    var first: [case_bytes_max]u8 = undefined;
    var second: [case_bytes_max]u8 = undefined;
    try std.testing.expectEqualStrings("e2e/misc/a.ink", case_name(&first, "misc/a.ink", "x"));
    const one = case_name(&first, null, "Hello\n");
    try std.testing.expectEqualStrings(one, case_name(&second, null, "Hello\n"));
    try std.testing.expect(std.mem.startsWith(u8, one, "e2e/inline/"));
}
