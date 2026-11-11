//! Checks the audit-bug registry, `test/known_bugs.zon` (plan P0.7): each bug with the issue
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
const old_compiler = @import("../compiler/compiler.zig");

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
    assert(registry_path.len > 0);
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
    assert(bugs.len > 0);
    return bugs;
}

fn is_issue(text: []const u8) bool {
    assert(text.len < 64);
    const result = std.mem.startsWith(u8, text, "TASK-") and text.len > "TASK-".len;
    if (result) assert(std.ascii.isDigit(text["TASK-".len]));
    return result;
}

fn is_semantic_kind(kind: oracle.Kind) bool {
    const index = @intFromEnum(kind);
    const result = index <= @intFromEnum(oracle.Kind.s11);
    comptime assert(@intFromEnum(oracle.Kind.s1) == 0);
    comptime assert(@intFromEnum(oracle.Kind.s11) == 10);
    return result;
}

test "every audit bug and audit divergence names its fixing issue" {
    // Goal: P0.7; nothing skipped can be forgotten before P9. Method: check the registry and
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
    try std.testing.expect(audit_entries > 0);
}

test "old compiler accepts broken source (skipped until TASK-147.8)" {
    // Goal: P0.7 records that compile() ignores errors. Method: compile source with an
    // unclosed brace, which ink rejects. While the old compiler accepts it, this skips; once
    // it rejects it, the test fails so the registry entry gets updated.
    const gpa = std.testing.allocator;
    const json = old_compiler.compile(gpa, "Hello {unclosed\n") catch return;
    gpa.free(json);
    std.debug.print("skipped: the old compiler accepts '{{unclosed' (fix: TASK-147.8)\n", .{});
    return error.SkipZigTest;
}
