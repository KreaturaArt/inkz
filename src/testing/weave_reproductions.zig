//! The weave-heuristic reproductions (plan P5.2). The P0.12 report found one old-runtime
//! heuristic firing, `divertTargetsAncestorOfAnyChoiceSource`, on three ground-truth cases,
//! equally for ink's compiler and the old one: a runtime gap, not old-compiler output. The
//! cases are ink's own minimal tests; the new VM has no heuristic code and must match ink on
//! each. `loopBackGatherTailPeel` never fired and has no reproduction.

const std = @import("std");
const assert = std.debug.assert;
const cases = @import("cases.zig");

const Reproduction = struct {
    id: []const u8,
    /// Actions replacing the case's own, with the transcript they give; null to replay the
    /// case's actions and compare with its `.expected` file.
    override: ?struct { actions: []const u8, expected: []const u8 } = null,
};

const reproductions = [_]Reproduction{
    .{ .id = "runtime/weaves/conditional_choice_in_weave" },
    .{ .id = "runtime/weaves/weave_within_sequence" },
    .{
        // The case's own actions save and load around the choice (P6); this is the rest.
        .id = "runtime/choices/choice_thread_forking",
        .override = .{
            .actions = "continue\nchoose 0\ncontinue_maximally",
            .expected = "> continue\ntext: \"\"\n> choose 0\n> continue_maximally\n" ++
                "text: \"A choice\\n\"\ntext: \"Vaue of local var is: 1\\n\"\n",
        },
    },
};

test "the weave-heuristic reproductions match ink on the new VM" {
    // Goal: P5.2. Method: replay each reproduction on the new engine and compare with ink's
    // transcript (from the case's .expected file).
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (reproductions) |reproduction| {
        assert(reproduction.id.len > 0);
        const actions = if (reproduction.override) |o| o.actions else null;
        const actual = try cases.replay_with(
            arena,
            std.testing.io,
            "new",
            reproduction.id,
            actions,
        );
        const expected = if (reproduction.override) |o| o.expected else try expected_of(
            arena,
            reproduction.id,
        );
        try std.testing.expectEqualStrings(expected, actual);
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
