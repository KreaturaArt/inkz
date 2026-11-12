//! The weave-heuristic reproductions (plan P5.2). The P0.12 report found one old-runtime
//! heuristic firing, `divertTargetsAncestorOfAnyChoiceSource`, on three ground-truth cases,
//! equally for ink's compiler and the old one: a runtime gap, not old-compiler output. The
//! cases are ink's own minimal tests; the new VM has no heuristic code and must match ink on
//! each. `loopBackGatherTailPeel` never fired and has no reproduction.

const std = @import("std");
const assert = std.debug.assert;

const new_engine_cases = @import("new_engine_cases.zig");

test "the weave-heuristic reproductions match ink on the new VM" {
    // Goal: P5.2. Method: replay each reproduction on the new engine and compare with ink's
    // transcript.
    try new_engine_cases.expect_cases_match(&.{
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
    });
}
