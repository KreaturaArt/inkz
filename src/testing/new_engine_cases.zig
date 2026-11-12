//! Ground-truth cases a Phase 5 item must pass on the new engine, as unit tests (plan P5.x):
//! each replays the case on the new VM and compares with ink's transcript. The oracle gate
//! covers every case; these name the ones each item is accepted on, so a regression points
//! at its item.

const std = @import("std");
const assert = std.debug.assert;
const cases = @import("cases.zig");

pub const Case = struct {
    id: []const u8,
    /// Actions replacing the case's own, with the transcript they give; null to replay the
    /// case's actions and compare with its `.expected` file.
    override: ?struct { actions: []const u8, expected: []const u8 } = null,
};

/// Replays every case on the new engine and expects ink's transcript.
pub fn expect_cases_match(case_list: []const Case) !void {
    assert(case_list.len > 0);
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (case_list) |case| {
        assert(case.id.len > 0);
        const actions = if (case.override) |o| o.actions else null;
        const io = std.testing.io;
        const actual = try cases.replay_with(arena, io, "new", case.id, actions);
        const expected = if (case.override) |o| o.expected else try expected_of(arena, case.id);
        std.testing.expectEqualStrings(expected, actual) catch |err| {
            std.debug.print("case {s}\n", .{case.id});
            return err;
        };
    }
}

/// The case's `.expected` transcript without its provenance header.
fn expected_of(arena: std.mem.Allocator, id: []const u8) ![]const u8 {
    assert(id.len > 0);
    const path = try std.fmt.allocPrint(arena, "{s}/{s}.expected", .{ cases.cases_directory, id });
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, arena, .limited(1 << 20));
    const header_end = std.mem.indexOfScalar(u8, text, '\n') orelse return text;
    assert(std.mem.startsWith(u8, text, "#"));
    return text[header_end + 1 ..];
}

test "P5.3: variables, scoping and pointers to temps passed into functions" {
    // Goal: P5.3; globals, temps and variable pointers scope as in ink, including a temp
    // passed by reference through nested functions (temp_global_conflict). Method: replay.
    try expect_cases_match(&.{
        .{ .id = "runtime/variables/temp_global_conflict" },
        .{ .id = "runtime/variables/variable_pointer_ref_from_knot" },
        .{ .id = "runtime/variables/variable_swap_recurse" },
        .{ .id = "runtime/variables/variable_declaration_in_conditional" },
        .{ .id = "runtime/variables/temporaries_at_global_scope" },
        .{ .id = "runtime/variables/variable_get_set_api" },
        .{ .id = "runtime/variables/set_non_existant_variable" },
        .{ .id = "runtime/variables/variable_divert_target" },
        .{ .id = "runtime/variables/variable_tunnel" },
        .{ .id = "runtime/logic/nested_pass_by_reference" },
        .{ .id = "runtime/evaluation/factorial_by_reference" },
        .{ .id = "runtime/lists/empty_list_origin_after_assignment" },
    });
}
