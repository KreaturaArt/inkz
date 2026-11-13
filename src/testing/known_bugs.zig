//! Checks the audit-bug registry, `test/known_bugs.zon`: each bug with the issue
//! that fixes it. Zero-debt rule: every one must be fixed by the end of P9.
//!
//! Most bugs are reproduced by a ground-truth case whose divergence is in the ledger, with
//! the fixing issue in its `fix` field; `case` names it. The rest can't be shown with a
//! transcript, and `status` says why. The tests below keep both lists honest: every bug and
//! every audit or S-kind ledger entry must name its fix, and a bug said to be in the ledger
//! must be there.

const std = @import("std");
const assert = std.debug.assert;
const oracle = @import("oracle.zig");
const new_grammar = @import("../compiler/grammar.zig");

pub const Status = enum {
    /// The case's divergence is in the ledger.
    in_ledger,
    /// The case matches ink: the bug didn't show. It stays as a regression guard.
    not_reproduced,
    /// No transcript can show it; `reason` says why.
    not_expressible,
    /// Already fixed in the old code.
    fixed,
};

pub const Bug = struct {
    name: []const u8,
    fix: []const u8,
    status: Status,
    case: []const u8 = "",
    reason: []const u8 = "",
};

pub const registry_path = "test/known_bugs.zon";

pub fn read_bugs(arena: std.mem.Allocator, io: std.Io) ![]const Bug {
    const source = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        registry_path,
        arena,
        .limited(1024 * 1024),
        .of(u8),
        0,
    );
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const bugs = std.zon.parse.fromSlice([]const Bug, .{
        .gpa = arena,
        .arena = arena,
        .source = source,
        .diagnostics = &diagnostics,
    }) catch |err| {
        diagnostics.log(registry_path);
        return err;
    };
    return bugs;
}

fn is_issue(text: []const u8) bool {
    assert(text.len < 64);
    const result = std.mem.startsWith(u8, text, "TASK-") and text.len > "TASK-".len;
    if (result) assert(std.ascii.isDigit(text["TASK-".len]));
    return result;
}

fn is_semantic_kind(kind: oracle.Kind) bool {
    const index = @backingInt(kind);
    const result = index <= @backingInt(oracle.Kind.s11);
    comptime assert(@backingInt(oracle.Kind.s1) == 0);
    comptime assert(@backingInt(oracle.Kind.s11) == 10);
    return result;
}

test "every audit bug and audit divergence names its fixing issue" {
    // Nothing skipped can be forgotten before P9: check the registry and
    // the ledger, and print the list.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ledger = try oracle.read_ledger(arena, std.testing.io);
    for (try read_bugs(arena, std.testing.io)) |bug| {
        try std.testing.expect(is_issue(bug.fix));
        if (bug.status == .not_expressible or bug.status == .fixed) {
            try std.testing.expect(bug.reason.len > 0);
        }
        if (bug.status != .in_ledger) continue;
        const listed = for (ledger) |entry| {
            if (std.mem.eql(u8, entry.case, bug.case) and std.mem.eql(u8, entry.fix, bug.fix)) {
                break true;
            }
        } else false;
        if (!listed) std.debug.print("missing from the ledger: {s}, {s}\n", .{ bug.case, bug.fix });
        try std.testing.expect(listed);
    }
    var audit_entries: u32 = 0;
    for (ledger) |entry| {
        const is_audit = std.mem.startsWith(u8, entry.case, "audit/");
        if (!is_audit and !is_semantic_kind(entry.kind)) continue;
        if (!is_issue(entry.fix)) std.debug.print("no fix named: {s}\n", .{entry.case});
        try std.testing.expect(is_issue(entry.fix));
        audit_entries += 1;
    }
    assert(audit_entries <= ledger.len);
}

test "the new front end reports an unclosed brace (TASK-147.8)" {
    // Fixes "compile() ignores errors" in the new front end: parse the
    // same source; it gets ink's diagnostics (the inner logic, then the line end).
    const gpa = std.testing.allocator;
    var parsed = try new_grammar.parse(gpa, "Hello {unclosed\n", .{});
    defer parsed.deinit(gpa);
    try std.testing.expect(parsed.diagnostics_count > 0);
    const expected: u32 = @backingInt(new_grammar.Expectation.inner_logic);
    try std.testing.expectEqual(expected, parsed.diagnostics()[0].extra);
}
