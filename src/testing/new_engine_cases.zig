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

test "P5.4: functions, tunnels, threads and externals" {
    // Goal: P5.4; ink's call stack semantics, bound externals with arguments as a stack
    // view, fallbacks, and a lookahead-unsafe external not called during the newline
    // lookahead (lookup_safe_or_not). Method: replay.
    try expect_cases_match(&.{
        .{ .id = "runtime/bindings/external_binding" },
        .{ .id = "runtime/bindings/lookup_safe_or_not" },
        .{ .id = "runtime/bindings/lookup_safe_or_not_with_post_glue" },
        .{ .id = "runtime/newlines/newlines_trimming_with_func_external_fallback" },
        .{ .id = "runtime/callstack/callstack_evaluation" },
        .{ .id = "runtime/evaluation/factorial_recursive" },
        .{ .id = "runtime/diverts/basic_tunnel" },
        .{ .id = "runtime/diverts/complex_tunnels" },
        .{ .id = "runtime/diverts/tunnel_onwards_after_tunnel" },
        .{ .id = "runtime/diverts/tunnel_onwards_divert_after_with_arg" },
        .{ .id = "runtime/diverts/tunnel_onwards_divert_override" },
        .{ .id = "runtime/diverts/tunnel_onwards_to_variable_divert_target" },
        .{ .id = "runtime/diverts/tunnel_onwards_with_param_default_choice" },
        .{ .id = "runtime/diverts/tunnel_vs_thread_behaviour" },
        .{ .id = "runtime/diverts/done_stops_thread" },
        .{ .id = "runtime/threads/multi_thread" },
        .{ .id = "runtime/threads/thread_done" },
        .{ .id = "runtime/threads/thread_in_logic" },
        .{ .id = "runtime/threads/top_flow_terminator_should_not_kill_thread_choices" },
        .{ .id = "runtime/knots/knot_thread_interaction" },
        .{ .id = "runtime/knots/knot_thread_interaction_2" },
        .{ .id = "runtime/glue/implicit_inline_glue_c" },
        .{ .id = "runtime/logic/print_num" },
    });
}

test "P5.10: errors and warnings where ink raises them" {
    // Goal: P5.10; ink's messages and prefixes, at ink's points: end-of-content errors,
    // value errors, the variable-not-found warning. Method: replay.
    try expect_cases_match(&.{
        .{ .id = "audit/errors_end_of_content" },
        .{ .id = "audit/errors_unfinished_tunnel" },
        .{ .id = "audit/errors_divert_to_non_target" },
        .{ .id = "audit/errors_runtime_values" },
        .{ .id = "runtime/variables/temp_not_found" },
        .{ .id = "runtime/variables/warn_variable_not_found_1" },
        .{ .id = "runtime/variables/warn_variable_not_found_2" },
    });
}

test "P5.5: line-based cont with glue, newlines, tags and default choices" {
    // Goal: P5.5; ink's Continue line by line: the newline lookahead with glue, tags on the
    // right line (including tags after a newline), invisible default choices, DONE and END.
    // Method: replay.
    try expect_cases_match(&.{
        .{ .id = "audit/lines_and_glue_lookahead" },
        .{ .id = "runtime/glue/implicit_inline_glue" },
        .{ .id = "runtime/glue/implicit_inline_glue_b" },
        .{ .id = "runtime/glue/implicit_inline_glue_c" },
        .{ .id = "runtime/glue/left_right_glue_matching" },
        .{ .id = "runtime/glue/simple_glue" },
        .{ .id = "runtime/newlines/newline_at_start_of_multiline_conditional" },
        .{ .id = "runtime/newlines/newline_consistency_1" },
        .{ .id = "runtime/newlines/newline_consistency_2" },
        .{ .id = "runtime/newlines/newline_consistency_3" },
        .{ .id = "runtime/newlines/newlines_with_string_eval" },
        .{ .id = "runtime/tags/tags" },
        .{ .id = "runtime/tags/tags_dynamic_content" },
        .{ .id = "runtime/tags/tags_in_choice" },
        .{ .id = "runtime/tags/tags_in_seq" },
        .{ .id = "runtime/choices/default_choices" },
        .{ .id = "runtime/choices/fallback_choice_on_thread" },
        .{ .id = "runtime/choices/choice_diverts_to_done" },
        .{ .id = "runtime/choices/various_default_choices" },
        .{ .id = "runtime/choices/state_rollback_over_default_choice" },
        .{ .id = "audit/errors_end_of_content" },
        .{ .id = "audit/errors_unfinished_tunnel" },
        .{ .id = "crime_scene" },
    });
}

test "P5.6: visit counts and turn indices" {
    // Goal: P5.6; ink's VisitChangedContainersDueToDivert and VisitContainer: diverts into
    // nested stitches and gathers, count_start_only (re-entering from inside), turn indices,
    // and returns from functions and tunnels that must not count. Method: replay.
    try expect_cases_match(&.{
        .{ .id = "audit/visits_on_divert_into_nested" },
        .{ .id = "audit/visits_count_start_only" },
        .{ .id = "audit/visits_function_return" },
        .{ .id = "audit/labels_per_knot" },
        .{ .id = "runtime/builtins/visit_counts_when_choosing" },
        .{ .id = "runtime/builtins/visit_count_bug_due_to_nested_containers" },
        .{ .id = "runtime/builtins/read_count_across_callstack" },
        .{ .id = "runtime/builtins/read_count_across_threads" },
        .{ .id = "runtime/builtins/read_count_dot_separated_path" },
        .{ .id = "runtime/builtins/read_count_variable_target" },
        .{ .id = "runtime/builtins/turns" },
        .{ .id = "runtime/builtins/turns_since" },
        .{ .id = "runtime/builtins/turns_since_nested" },
        .{ .id = "runtime/builtins/turns_since_with_variable_target" },
        .{ .id = "runtime/knots/knot_stitch_gather_counts" },
        .{ .id = "runtime/sequences/gather_read_count_with_initial_sequence" },
        .{ .id = "runtime/choices/once_only_choices_can_link_back_to_self" },
    });
}

test "P5.7: observers batched per cont, immediate outside it" {
    // Goal: P5.7; each observer fires once per variable per cont, after the line, with the
    // latest value; changes in a discarded lookahead aren't notified; a host set outside
    // cont fires at once. Method: replay.
    try expect_cases_match(&.{
        .{ .id = "audit/observers_batched" },
        .{ .id = "runtime/bindings/variable_observer" },
    });
}

test "P5.8: evaluate_function on the live state" {
    // Goal: P5.8; ink's EvaluateFunction: the output is set aside, side effects persist,
    // text is cleaned, a divert target comes back as its path, and an external may
    // evaluate (game_ink_back_and_forth). Method: replay.
    try expect_cases_match(&.{
        .{ .id = "audit/evaluate_function_side_effects" },
        .{ .id = "runtime/evaluation/evaluating_ink_functions_from_game" },
        .{ .id = "runtime/evaluation/evaluating_ink_functions_from_game_2" },
        .{ .id = "runtime/evaluation/evaluating_function_variable_state_bug" },
        .{ .id = "runtime/bindings/game_ink_back_and_forth" },
    });
}

test "P5.9: RANDOM, SEED_RANDOM, LIST_RANDOM and shuffles" {
    // Goal: P5.9; .NET Random seeded with storySeed + previousRandom, a fixed storySeed,
    // shuffles seeded by the UTF-16 path hash, and RANDOM's range overflow error. Method:
    // replay.
    try expect_cases_match(&.{
        .{ .id = "audit/random_seed_and_sequence" },
        .{ .id = "audit/random_range_limits" },
        .{ .id = "audit/unicode_paths" },
        .{ .id = "runtime/lists/list_random" },
        .{ .id = "runtime/sequences/all_sequence_types" },
        .{ .id = "runtime/sequences/shuffle_stack_muddying" },
        .{ .id = "runtime/sequences/blanks_in_inline_sequences" },
        .{ .id = "runtime/sequences/empty_sequence_content" },
    });
}

test "P6.3: host events fire at ink's points" {
    // Goal: P6.3 (D22); did_continue, make_choice, evaluate_function and its completion,
    // choose_path_string, recorded as the harness records ink's events. Method: replay.
    try expect_cases_match(&.{.{ .id = "audit/host_events" }});
}
