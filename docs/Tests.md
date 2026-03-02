## Compiled fixtures

### 26 directories, 177 files:

```
test/fixture/compiled/
├── player
│   ├── error_and_exceptions.ink.json
│   ├── error_and_exceptions.ink.json.import
│   ├── flow.ink.json
│   ├── flow.ink.json.import
│   ├── functions.ink.json
│   ├── functions.ink.json.import
│   ├── ink_error.ink.json
│   ├── ink_error.ink.json.import
│   ├── ink_list_roundtrip.ink.json
│   ├── ink_list_roundtrip.ink.json.import
│   ├── variable_observation.ink.json
│   ├── variable_observation.ink.json.import
│   ├── variables.ink.json
│   └── variables.ink.json.import
└── runtime
    ├── bindings
    │   ├── external_binding.ink.json
    │   ├── game_ink_back_and_forth.ink.json
    │   ├── lookup_safe_or_not_with_post_glue.ink.json
    │   ├── lookup_safe_or_not.ink.json
    │   └── variable_observer.ink.json
    ├── booleans
    │   ├── false_plus_false.ink.json
    │   ├── list_hasnt.ink.json
    │   ├── not_one.ink.json
    │   ├── not_true.ink.json
    │   ├── three_greater_than_one.ink.json
    │   ├── true_equals_one.ink.json
    │   ├── true_plus_one.ink.json
    │   ├── true_plus_true.ink.json
    │   ├── true.ink.json
    │   └── two_plus_true.ink.json
    ├── builtins
    │   ├── floor_ceiling_and_casts.ink.json
    │   ├── read_count_across_callstack.ink.json
    │   ├── read_count_across_threads.ink.json
    │   ├── read_count_dot_separated_path.ink.json
    │   ├── read_count_variable_target.ink.json
    │   ├── turns_since_nested.ink.json
    │   ├── turns_since_with_variable_target.ink.json
    │   ├── turns_since.ink.json
    │   ├── turns.ink.json
    │   ├── visit_count_bug_due_to_nested_containers.ink.json
    │   └── visit_counts_when_choosing.ink.json
    ├── callstack
    │   ├── call_stack_evaluation.ink.json
    │   ├── callstack_evaluation.ink.json
    │   └── clean_callstack_reset_on_path_choice.ink.json
    ├── choices
    │   ├── choice_count.ink.json
    │   ├── choice_diverts_to_done.ink.json
    │   ├── choice_thread_forking.ink.json
    │   ├── choice_with_brackets_only.ink.json
    │   ├── conditional_choices.ink.json
    │   ├── default_choices.ink.json
    │   ├── default_simple_gather.ink.json
    │   ├── fallback_choice_on_thread.ink.json
    │   ├── gather_choice_same_line.ink.json
    │   ├── has_read_on_choice.ink.json
    │   ├── logic_in_choices.ink.json
    │   ├── non_text_in_choice_inner_content.ink.json
    │   ├── once_only_choices_can_link_back_to_self.ink.json
    │   ├── once_only_choices_with_own_content.ink.json
    │   ├── should_not_gather_due_to_choice.ink.json
    │   ├── state_rollback_over_default_choice.ink.json
    │   ├── sticky_choices_stay_sticky.ink.json
    │   └── various_default_choices.ink.json
    ├── conditions
    │   ├── all_switch_branches_fail_is_clean.ink.json
    │   ├── conditionals.ink.json
    │   ├── else_branches.ink.json
    │   ├── empty_multiline_conditional_branch.ink.json
    │   └── trivial_condition.ink.json
    ├── diverts
    │   ├── basic_tunnel.ink.json
    │   ├── compare_divert_targets.ink.json
    │   ├── complex_tunnels.ink.json
    │   ├── divert_in_conditional.ink.json
    │   ├── divert_targets_with_parameters.ink.json
    │   ├── divert_to_weave_points.ink.json
    │   ├── done_stops_thread.ink.json
    │   ├── path_to_self.ink.json
    │   ├── same_line_divert_is_inline.ink.json
    │   ├── tunnel_onwards_after_tunnel.ink.json
    │   ├── tunnel_onwards_divert_after_with_arg.ink.json
    │   ├── tunnel_onwards_divert_override.ink.json
    │   ├── tunnel_onwards_to_variable_divert_target.ink.json
    │   ├── tunnel_onwards_with_param_default_choice.ink.json
    │   └── tunnel_vs_thread_behaviour.ink.json
    ├── evaluation
    │   ├── arithmetic.ink.json
    │   ├── basic_string_literals.ink.json
    │   ├── evaluating_function_variable_state_bug.ink.json
    │   ├── evaluating_ink_functions_from_game_2.ink.json
    │   ├── evaluating_ink_functions_from_game.ink.json
    │   ├── evaluation_stack_leaks.ink.json
    │   ├── factorial_by_reference.ink.json
    │   ├── factorial_recursive.ink.json
    │   ├── increment.ink.json
    │   └── literal_unary.ink.json
    ├── extra
    │   ├── arithmetic_2.ink.json
    │   └── list_comparison.ink.json
    ├── glue
    │   ├── implicit_inline_glue_b.ink.json
    │   ├── implicit_inline_glue_c.ink.json
    │   ├── implicit_inline_glue.ink.json
    │   ├── left_right_glue_matching.ink.json
    │   └── simple_glue.ink.json
    ├── knots
    │   ├── knot_do_not_gather.ink.json
    │   ├── knot_stitch_gather_counts.ink.json
    │   ├── knot_thread_interaction_2.ink.json
    │   └── knot_thread_interaction.ink.json
    ├── lists
    │   ├── contains_empty_list_always_false.ink.json
    │   ├── empty_list_origin_after_assignment.ink.json
    │   ├── empty_list_origin.ink.json
    │   ├── list_basic_operations.ink.json
    │   ├── list_mixed_items.ink.json
    │   ├── list_random.ink.json
    │   ├── list_range.ink.json
    │   ├── list_save_load.ink.json
    │   └── more_list_operations.ink.json
    ├── logic
    │   ├── logic_lines_with_newlines.ink.json
    │   ├── multiline_logic_with_glue.ink.json
    │   ├── nested_pass_by_reference.ink.json
    │   └── print_num.ink.json
    ├── misc
    │   ├── empty.ink.json
    │   ├── end_of_content.ink.json
    │   ├── end.ink.json
    │   ├── end2.ink.json
    │   ├── escape_character.ink.json
    │   ├── hello_world.ink.json
    │   ├── identifiers_can_start_with_number.ink.json
    │   ├── include.ink.json
    │   ├── includes
    │   │   ├── included_file_2.ink.json
    │   │   ├── included_file_4.ink.json
    │   │   └── included_file.ink.json
    │   ├── nested_include.ink.json
    │   ├── quote_character_significance.ink.json
    │   └── whitespace.ink.json
    ├── multiflow
    │   ├── multi_flow_basics.ink.json
    │   └── multi_flow_save_load_threads.ink.json
    ├── newlines
    │   ├── newline_at_start_of_multiline_conditional.ink.json
    │   ├── newline_consistency_1.ink.json
    │   ├── newline_consistency_2.ink.json
    │   ├── newline_consistency_3.ink.json
    │   ├── newlines_trimming_with_func_external_fallback.ink.json
    │   └── newlines_with_string_eval.ink.json
    ├── sequences
    │   ├── all_sequence_types.ink.json
    │   ├── blanks_in_inline_sequences.ink.json
    │   ├── empty_sequence_content.ink.json
    │   ├── gather_read_count_with_initial_sequence.ink.json
    │   ├── leading_newline_multiline_sequence.ink.json
    │   └── shuffle_stack_muddying.ink.json
    ├── strings
    │   ├── string_constants.ink.json
    │   ├── string_contains.ink.json
    │   ├── string_type_coercion.ink.json
    │   └── strings_in_choices.ink.json
    ├── tags
    │   ├── tags_dynamic_content.ink.json
    │   ├── tags_in_choice.ink.json
    │   ├── tags_in_seq.ink.json
    │   ├── tags_on_choice.ink.json
    │   └── tags.ink.json
    ├── threads
    │   ├── multi_thread.ink.json
    │   ├── thread_done.ink.json
    │   ├── thread_in_logic.ink.json
    │   └── top_flow_terminator_should_not_kill_thread_choices.ink.json
    ├── variables
    │   ├── const.ink.json
    │   ├── multiple_constant_references.ink.json
    │   ├── set_non_existant_variable.ink.json
    │   ├── temp_global_conflict.ink.json
    │   ├── temp_not_found.ink.json
    │   ├── temp_usage_in_options.ink.json
    │   ├── temporaries_at_global_scope.ink.json
    │   ├── variable_declaration_in_conditional.ink.json
    │   ├── variable_divert_target.ink.json
    │   ├── variable_get_set_api.ink.json
    │   ├── variable_pointer_ref_from_knot.ink.json
    │   ├── variable_swap_recurse.ink.json
    │   ├── variable_tunnel.ink.json
    │   ├── warn_variable_not_found_1.ink.json
    │   └── warn_variable_not_found_2.ink.json
    └── weaves
        ├── conditional_choice_in_weave_2.ink.json
        ├── conditional_choice_in_weave.ink.json
        ├── unbalanced_weave_indentation.ink.json
        ├── weave_gathers.ink.json
        ├── weave_options.ink.json
        └── weave_within_sequence.ink.json
```