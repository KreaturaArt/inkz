## Fixture Test Coverage

This document is generated from direct fixture references in `src/**/*.zig` test code.
A fixture is marked unused when no unit test references that file directly; it may still be exercised indirectly via another fixture, for example `INCLUDE` targets.

## Summary

- Original fixtures: `169` `.ink` files
- Compiled fixtures: `170` `.ink.json` files
- Auxiliary compiled files: `7` `.import` files
- Original fixtures unused in direct unit tests: `26`
- Compiled fixtures unused in direct unit tests: `3`

## Original Fixtures

#### `player/`

- `error_and_exceptions.ink`
  - "Compiler e2e: player/error_and_exceptions.ink" — `src/test/compiler_helpers.zig`
- `flow.ink`
  - "Compiler e2e: player/flow.ink" — `src/test/compiler_helpers.zig`
- `functions.ink`
  - "Compiler e2e: player/functions.ink" — `src/test/compiler_helpers.zig`
- `ink_error.ink`
  - "Compiler e2e: player/ink_error.ink" — `src/test/compiler_helpers.zig`
- `ink_list_roundtrip.ink`
  - "Compiler e2e: player/ink_list_roundtrip.ink" — `src/test/compiler_helpers.zig`
- `variable_observation.ink`
  - "Compiler e2e: player/variable_observation.ink" — `src/test/compiler_helpers.zig`
- `variables.ink`
  - "Compiler e2e: player/variables.ink" — `src/test/compiler_helpers.zig`

#### `runtime/bindings/`

- `external_binding.ink`
  - "Compiler e2e: runtime/bindings/external_binding.ink" — `src/test/compiler_helpers.zig`
- `game_ink_back_and_forth.ink`
  - "Compiler e2e: runtime/bindings/game_ink_back_and_forth.ink" — `src/test/compiler_helpers.zig`
- `lookup_safe_or_not.ink`
  - "Compiler e2e: runtime/bindings/lookup_safe_or_not.ink" — `src/test/compiler_helpers.zig`
- `lookup_safe_or_not_with_post_glue.ink`
  - "Compiler e2e: runtime/bindings/lookup_safe_or_not_with_post_glue.ink" — `src/test/compiler_helpers.zig`
- `variable_observer.ink`
  - "Compiler e2e: runtime/bindings/variable_observer.ink" — `src/test/compiler_helpers.zig`

#### `runtime/booleans/`

- `false_plus_false.ink`
  - "Compiler e2e: booleans/false_plus_false.ink" — `src/test/compiler_helpers.zig`
- `list_hasnt.ink`
  - "Compiler e2e: booleans/list_hasnt.ink" — `src/test/compiler_helpers.zig`
- `not_one.ink`
  - "Compiler e2e: booleans/not_one.ink" — `src/test/compiler_helpers.zig`
- `not_true.ink`
  - "Compiler e2e: booleans/not_true.ink" — `src/test/compiler_helpers.zig`
- `three_greater_than_one.ink`
  - "Compiler e2e: booleans/three_greater_than_one.ink" — `src/test/compiler_helpers.zig`
- `true.ink`
  - "Compiler e2e: booleans/true.ink" — `src/test/compiler_helpers.zig`
- `true_equals_one.ink`
  - Unused in direct unit tests
- `true_plus_one.ink`
  - Unused in direct unit tests
- `true_plus_true.ink`
  - Unused in direct unit tests
- `two_plus_true.ink`
  - Unused in direct unit tests

#### `runtime/builtins/`

- `floor_ceiling_and_casts.ink`
  - "Compiler e2e: builtins/floor_ceiling_and_casts.ink" — `src/test/compiler_helpers.zig`
- `read_count_across_callstack.ink`
  - "Compiler e2e: read_count_across_callstack.ink" — `src/test/compiler_helpers.zig`
- `read_count_across_threads.ink`
  - "Compiler e2e: builtins/read_count_across_threads.ink" — `src/test/compiler_helpers.zig`
- `read_count_dot_separated_path.ink`
  - "Compiler e2e: builtins/read_count_dot_separated_path.ink" — `src/test/compiler_helpers.zig`
- `read_count_variable_target.ink`
  - Unused in direct unit tests
- `turns.ink`
  - "Compiler e2e: TURNS() built-in" — `src/test/compiler_helpers.zig`
- `turns_since.ink`
  - "Compiler e2e: TURNS_SINCE built-in" — `src/test/compiler_helpers.zig`
- `turns_since_nested.ink`
  - "Compiler e2e: builtins/turns_since_nested.ink" — `src/test/compiler_helpers.zig`
- `turns_since_with_variable_target.ink`
  - Unused in direct unit tests
- `visit_count_bug_due_to_nested_containers.ink`
  - "Compiler e2e: builtins/visit_count_bug_due_to_nested_containers.ink" — `src/test/compiler_helpers.zig`
- `visit_counts_when_choosing.ink`
  - Unused in direct unit tests

#### `runtime/callstack/`

- `callstack_evaluation.ink`
  - "Compiler e2e: callstack_evaluation.ink — return with expr" — `src/test/compiler_helpers.zig`
  - "Compiler e2e: callstack_evaluation.ink" — `src/test/compiler_helpers.zig`
- `clean_callstack_reset_on_path_choice.ink`
  - "Compiler e2e: callstack/clean_callstack_reset_on_path_choice.ink" — `src/test/compiler_helpers.zig`

#### `runtime/choices/`

- `choice_count.ink`
  - "Compiler e2e: CHOICE_COUNT built-in" — `src/test/compiler_helpers.zig`
- `choice_diverts_to_done.ink`
  - "Compiler e2e: choice_diverts_to_done.ink — start-text choice" — `src/test/compiler_helpers.zig`
- `choice_thread_forking.ink`
  - Unused in direct unit tests
- `choice_with_brackets_only.ink`
  - "Compiler e2e: choice_with_brackets_only.ink — brackets-only choice" — `src/test/compiler_helpers.zig`
- `conditional_choices.ink`
  - "Compiler e2e: conditional_choices.ink — single-condition choices" — `src/test/compiler_helpers.zig`
- `default_choices.ink`
  - "Compiler e2e: default_choices.ink — named gather + loop" — `src/test/compiler_helpers.zig`
- `default_simple_gather.ink`
  - "Compiler e2e: default_simple_gather.ink — fallback choice + gather" — `src/test/compiler_helpers.zig`
- `fallback_choice_on_thread.ink`
  - Unused in direct unit tests
- `gather_choice_same_line.ink`
  - "Compiler e2e: gather_choice_same_line.ink" — `src/test/compiler_helpers.zig`
- `has_read_on_choice.ink`
  - "Compiler e2e: has_read_on_choice.ink — condition on knot read count" — `src/test/compiler_helpers.zig`
- `logic_in_choices.ink`
  - "Compiler e2e: logic_in_choices.ink — function call in choice text" — `src/test/compiler_helpers.zig`
- `non_text_in_choice_inner_content.ink`
  - "Compiler e2e: non_text_in_choice_inner_content.ink" — `src/test/compiler_helpers.zig`
- `once_only_choices_can_link_back_to_self.ink`
  - "Compiler e2e: once_only_choices_can_link_back_to_self.ink" — `src/test/compiler_helpers.zig`
- `once_only_choices_with_own_content.ink`
  - "Compiler e2e: choices/once_only_choices_with_own_content.ink" — `src/test/compiler_helpers.zig`
- `should_not_gather_due_to_choice.ink`
  - "Compiler e2e: should_not_gather_due_to_choice.ink" — `src/test/compiler_helpers.zig`
- `state_rollback_over_default_choice.ink`
  - "Compiler e2e: choices/state_rollback_over_default_choice.ink" — `src/test/compiler_helpers.zig`
- `sticky_choices_stay_sticky.ink`
  - "Compiler e2e: sticky_choices_stay_sticky.ink" — `src/test/compiler_helpers.zig`
- `various_default_choices.ink`
  - "Compiler e2e: choices/various_default_choices.ink" — `src/test/compiler_helpers.zig`

#### `runtime/conditions/`

- `all_switch_branches_fail_is_clean.ink`
  - "Compiler e2e: all_switch_branches_fail_is_clean.ink fixture" — `src/test/compiler_helpers.zig`
- `conditionals.ink`
  - "Compiler e2e: conditionals.ink fixture" — `src/test/compiler_helpers.zig`
- `else_branches.ink`
  - "Compiler e2e: else_branches.ink fixture" — `src/test/compiler_helpers.zig`
- `empty_multiline_conditional_branch.ink`
  - "Compiler e2e: empty_multiline_conditional_branch.ink fixture" — `src/test/compiler_helpers.zig`
- `trivial_condition.ink`
  - "Compiler e2e: trivial_condition.ink fixture" — `src/test/compiler_helpers.zig`

#### `runtime/diverts/`

- `basic_tunnel.ink`
  - "Compiler e2e: basic_tunnel.ink" — `src/test/compiler_helpers.zig`
- `compare_divert_targets.ink`
  - "Compiler e2e: diverts/compare_divert_targets.ink" — `src/test/compiler_helpers.zig`
- `complex_tunnels.ink`
  - "Compiler e2e: diverts/complex_tunnels.ink" — `src/test/compiler_helpers.zig`
- `divert_in_conditional.ink`
  - "Compiler e2e: diverts/divert_in_conditional.ink" — `src/test/compiler_helpers.zig`
- `divert_targets_with_parameters.ink`
  - "Compiler e2e: diverts/divert_targets_with_parameters.ink" — `src/test/compiler_helpers.zig`
- `divert_to_weave_points.ink`
  - "Compiler e2e: diverts/divert_to_weave_points.ink" — `src/test/compiler_helpers.zig`
- `done_stops_thread.ink`
  - "Compiler e2e: diverts/done_stops_thread.ink" — `src/test/compiler_helpers.zig`
- `path_to_self.ink`
  - "Compiler e2e: diverts/path_to_self.ink" — `src/test/compiler_helpers.zig`
- `same_line_divert_is_inline.ink`
  - "Compiler e2e: diverts/same_line_divert_is_inline.ink" — `src/test/compiler_helpers.zig`
- `tunnel_onwards_after_tunnel.ink`
  - "Compiler e2e: tunnel_onwards_after_tunnel.ink" — `src/test/compiler_helpers.zig`
- `tunnel_onwards_divert_after_with_arg.ink`
  - "Compiler e2e: diverts/tunnel_onwards_divert_after_with_arg.ink" — `src/test/compiler_helpers.zig`
- `tunnel_onwards_divert_override.ink`
  - "Compiler e2e: diverts/tunnel_onwards_divert_override.ink" — `src/test/compiler_helpers.zig`
- `tunnel_onwards_to_variable_divert_target.ink`
  - "Compiler e2e: diverts/tunnel_onwards_to_variable_divert_target.ink" — `src/test/compiler_helpers.zig`
- `tunnel_onwards_with_param_default_choice.ink`
  - "Compiler e2e: diverts/tunnel_onwards_with_param_default_choice.ink" — `src/test/compiler_helpers.zig`
- `tunnel_vs_thread_behaviour.ink`
  - "Compiler e2e: diverts/tunnel_vs_thread_behaviour.ink" — `src/test/compiler_helpers.zig`

#### `runtime/evaluation/`

- `arithmetic.ink`
  - "Compiler e2e: arithmetic.ink fixture" — `src/test/compiler_helpers.zig`
  - "Compiler tokenizer: arithmetic.ink" — `src/compiler/tokenizer.zig`
- `basic_string_literals.ink`
  - "Compiler e2e: evaluation/basic_string_literals.ink" — `src/test/compiler_helpers.zig`
- `evaluating_function_variable_state_bug.ink`
  - "Compiler e2e: evaluation/evaluating_function_variable_state_bug.ink" — `src/test/compiler_helpers.zig`
- `evaluating_ink_functions_from_game.ink`
  - Unused in direct unit tests
- `evaluating_ink_functions_from_game_2.ink`
  - Unused in direct unit tests
- `evaluation_stack_leaks.ink`
  - "Compiler e2e: evaluation/evaluation_stack_leaks.ink" — `src/test/compiler_helpers.zig`
- `factorial_by_reference.ink`
  - "Compiler e2e: evaluation/factorial_by_reference.ink" — `src/test/compiler_helpers.zig`
- `factorial_recursive.ink`
  - "Compiler e2e: evaluation/factorial_recursive.ink" — `src/test/compiler_helpers.zig`
- `increment.ink`
  - "Compiler e2e: evaluation/increment.ink" — `src/test/compiler_helpers.zig`
- `literal_unary.ink`
  - "Compiler e2e: evaluation/literal_unary.ink" — `src/test/compiler_helpers.zig`

#### `runtime/extra/`

- `arithmetic_2.ink`
  - "Compiler e2e: extra/arithmetic_2.ink" — `src/test/compiler_helpers.zig`
- `list_comparison.ink`
  - "Compiler e2e: extra/list_comparison.ink" — `src/test/compiler_helpers.zig`

#### `runtime/glue/`

- `implicit_inline_glue.ink`
  - "Compiler e2e: glue/implicit_inline_glue.ink" — `src/test/compiler_helpers.zig`
- `implicit_inline_glue_b.ink`
  - "Compiler e2e: glue/implicit_inline_glue_b.ink" — `src/test/compiler_helpers.zig`
- `implicit_inline_glue_c.ink`
  - "Compiler e2e: glue/implicit_inline_glue_c.ink" — `src/test/compiler_helpers.zig`
- `left_right_glue_matching.ink`
  - "Compiler e2e: left_right_glue_matching.ink" — `src/test/compiler_helpers.zig`
- `simple_glue.ink`
  - "Compiler e2e: simple_glue.ink" — `src/test/compiler_helpers.zig`

#### `runtime/knots/`

- `knot_do_not_gather.ink`
  - "Compiler e2e: knots/knot_do_not_gather.ink" — `src/test/compiler_helpers.zig`
  - "Compiler parser: knot_do_not_gather.ink knot name" — `src/compiler/parser.zig`
- `knot_stitch_gather_counts.ink`
  - "Compiler e2e: knots/knot_stitch_gather_counts.ink" — `src/test/compiler_helpers.zig`
  - "Compiler parser: stitch_gather_counts VAR in knot" — `src/compiler/parser.zig`
- `knot_thread_interaction.ink`
  - "Compiler e2e: knots/knot_thread_interaction.ink" — `src/test/compiler_helpers.zig`
  - "Compiler parser: knot_thread_interaction knot names" — `src/compiler/parser.zig`
- `knot_thread_interaction_2.ink`
  - "Compiler e2e: knots/knot_thread_interaction_2.ink" — `src/test/compiler_helpers.zig`

#### `runtime/lists/`

- `contains_empty_list_always_false.ink`
  - Unused in direct unit tests
- `empty_list_origin.ink`
  - "Compiler e2e: LIST empty_list_origin" — `src/test/compiler_helpers.zig`
- `empty_list_origin_after_assignment.ink`
  - Unused in direct unit tests
- `list_basic_operations.ink`
  - "Compiler e2e: LIST basic" — `src/test/compiler_helpers.zig`
- `list_mixed_items.ink`
  - Unused in direct unit tests
- `list_random.ink`
  - Unused in direct unit tests
- `list_range.ink`
  - Unused in direct unit tests
- `list_save_load.ink`
  - Unused in direct unit tests
- `more_list_operations.ink`
  - "Compiler e2e: LIST more_list_operations" — `src/test/compiler_helpers.zig`

#### `runtime/logic/`

- `logic_lines_with_newlines.ink`
  - "Compiler e2e: logic/logic_lines_with_newlines.ink" — `src/test/compiler_helpers.zig`
- `multiline_logic_with_glue.ink`
  - "Compiler e2e: logic/multiline_logic_with_glue.ink" — `src/test/compiler_helpers.zig`
- `nested_pass_by_reference.ink`
  - "Compiler e2e: logic/nested_pass_by_reference.ink" — `src/test/compiler_helpers.zig`
- `print_num.ink`
  - "Compiler e2e: logic/print_num.ink" — `src/test/compiler_helpers.zig`

#### `runtime/misc/`

- `empty.ink`
  - "Compiler e2e: misc/empty.ink fixture" — `src/test/compiler_helpers.zig`
- `end.ink`
  - "Compiler e2e: misc/end.ink fixture" — `src/test/compiler_helpers.zig`
- `end2.ink`
  - "Compiler e2e: misc/end2.ink fixture" — `src/test/compiler_helpers.zig`
- `end_of_content.ink`
  - "Compiler e2e: misc/end_of_content.ink fixture" — `src/test/compiler_helpers.zig`
  - "Compiler parser: end_of_content.ink knot name" — `src/compiler/parser.zig`
- `escape_character.ink`
  - "Compiler e2e: misc/escape_character.ink" — `src/test/compiler_helpers.zig`
- `hello_world.ink`
  - "Compiler e2e: misc/hello_world.ink fixture" — `src/test/compiler_helpers.zig`
  - "Compiler parser: hello_world.ink root_content" — `src/compiler/parser.zig`
  - "Compiler tokenizer: hello_world.ink" — `src/compiler/tokenizer.zig`
- `identifiers_can_start_with_number.ink`
  - "Compiler e2e: misc/identifiers_can_start_with_number.ink" — `src/test/compiler_helpers.zig`
- `include.ink`
  - "Compiler parser: INCLUDE paths" — `src/compiler/parser.zig`
- `nested_include.ink`
  - Unused in direct unit tests
- `quote_character_significance.ink`
  - "Compiler e2e: misc/quote_character_significance.ink" — `src/test/compiler_helpers.zig`
- `whitespace.ink`
  - "Compiler e2e: misc/whitespace.ink fixture" — `src/test/compiler_helpers.zig`

#### `runtime/misc/includes/`

- `included_file.ink`
  - Unused in direct unit tests
- `included_file_2.ink`
  - Unused in direct unit tests
- `included_file_3.ink`
  - Unused in direct unit tests
- `included_file_4.ink`
  - Unused in direct unit tests

#### `runtime/multiflow/`

- `multi_flow_basics.ink`
  - Unused in direct unit tests
- `multi_flow_save_load_threads.ink`
  - Unused in direct unit tests

#### `runtime/newlines/`

- `newline_at_start_of_multiline_conditional.ink`
  - "Compiler e2e: newline_at_start_of_multiline_conditional.ink" — `src/test/compiler_helpers.zig`
- `newline_consistency_1.ink`
  - "Compiler e2e: newline_consistency_1.ink" — `src/test/compiler_helpers.zig`
- `newline_consistency_2.ink`
  - "Compiler e2e: newline_consistency_2.ink" — `src/test/compiler_helpers.zig`
- `newline_consistency_3.ink`
  - "Compiler e2e: newlines/newline_consistency_3.ink" — `src/test/compiler_helpers.zig`
- `newlines_trimming_with_func_external_fallback.ink`
  - Unused in direct unit tests
- `newlines_with_string_eval.ink`
  - "Compiler e2e: newlines/newlines_with_string_eval.ink" — `src/test/compiler_helpers.zig`

#### `runtime/sequences/`

- `all_sequence_types.ink`
  - "Compiler e2e: sequences/all_sequence_types.ink" — `src/test/compiler_helpers.zig`
- `blanks_in_inline_sequences.ink`
  - "Compiler e2e: sequences/blanks_in_inline_sequences.ink" — `src/test/compiler_helpers.zig`
- `empty_sequence_content.ink`
  - "Compiler e2e: empty_sequence_content.ink fixture" — `src/test/compiler_helpers.zig`
- `gather_read_count_with_initial_sequence.ink`
  - "Compiler e2e: sequences/gather_read_count_with_initial_sequence.ink" — `src/test/compiler_helpers.zig`
- `leading_newline_multiline_sequence.ink`
  - "Compiler e2e: leading_newline_multiline_sequence.ink fixture" — `src/test/compiler_helpers.zig`
- `shuffle_stack_muddying.ink`
  - "Compiler e2e: sequences/shuffle_stack_muddying.ink" — `src/test/compiler_helpers.zig`

#### `runtime/strings/`

- `string_constants.ink`
  - "Compiler e2e: string_constants.ink" — `src/test/compiler_helpers.zig`
- `string_contains.ink`
  - Unused in direct unit tests
- `string_type_coercion.ink`
  - "Compiler e2e: strings/string_type_coercion.ink" — `src/test/compiler_helpers.zig`
- `strings_in_choices.ink`
  - "Compiler e2e: strings/strings_in_choices.ink" — `src/test/compiler_helpers.zig`

#### `runtime/tags/`

- `tags.ink`
  - "Compiler e2e: tags.ink fixture" — `src/test/compiler_helpers.zig`
- `tags_dynamic_content.ink`
  - "Compiler e2e: tags/tags_dynamic_content.ink" — `src/test/compiler_helpers.zig`
- `tags_in_choice.ink`
  - "Compiler e2e: tags/tags_in_choice.ink" — `src/test/compiler_helpers.zig`
- `tags_in_seq.ink`
  - "Compiler e2e: tags/tags_in_seq.ink" — `src/test/compiler_helpers.zig`

#### `runtime/threads/`

- `multi_thread.ink`
  - "Compiler e2e: threads/multi_thread.ink" — `src/test/compiler_helpers.zig`
- `thread_done.ink`
  - "Compiler e2e: thread_done.ink" — `src/test/compiler_helpers.zig`
- `thread_in_logic.ink`
  - "Compiler e2e: thread in sequence" — `src/test/compiler_helpers.zig`
- `top_flow_terminator_should_not_kill_thread_choices.ink`
  - "Compiler e2e: threads/top_flow_terminator_should_not_kill_thread_choices.ink" — `src/test/compiler_helpers.zig`

#### `runtime/variables/`

- `const.ink`
  - "Compiler e2e: const.ink fixture" — `src/test/compiler_helpers.zig`
  - "Compiler parser: CONST declarations" — `src/compiler/parser.zig`
- `multiple_constant_references.ink`
  - "Compiler e2e: multiple_constant_references.ink" — `src/test/compiler_helpers.zig`
- `set_non_existant_variable.ink`
  - "Compiler e2e: variables/set_non_existant_variable.ink" — `src/test/compiler_helpers.zig`
- `temp_global_conflict.ink`
  - "Compiler e2e: variables/temp_global_conflict.ink" — `src/test/compiler_helpers.zig`
- `temp_not_found.ink`
  - "Compiler e2e: variables/temp_not_found.ink" — `src/test/compiler_helpers.zig`
- `temp_usage_in_options.ink`
  - "Compiler e2e: variables/temp_usage_in_options.ink" — `src/test/compiler_helpers.zig`
- `temporaries_at_global_scope.ink`
  - "Compiler e2e: temporaries_at_global_scope.ink fixture" — `src/test/compiler_helpers.zig`
- `variable_declaration_in_conditional.ink`
  - "Compiler e2e: variable_declaration_in_conditional.ink" — `src/test/compiler_helpers.zig`
- `variable_divert_target.ink`
  - "Compiler e2e: variable_divert_target.ink" — `src/test/compiler_helpers.zig`
- `variable_get_set_api.ink`
  - "Compiler parser: VAR declarations" — `src/compiler/parser.zig`
- `variable_pointer_ref_from_knot.ink`
  - "Compiler e2e: variables/variable_pointer_ref_from_knot.ink" — `src/test/compiler_helpers.zig`
- `variable_swap_recurse.ink`
  - "Compiler e2e: variable_swap_recurse.ink — params + recursion" — `src/test/compiler_helpers.zig`
- `variable_tunnel.ink`
  - "Compiler e2e: variables/variable_tunnel.ink" — `src/test/compiler_helpers.zig`
- `warn_variable_not_found_1.ink`
  - "Compiler e2e: variables/warn_variable_not_found_1.ink" — `src/test/compiler_helpers.zig`
- `warn_variable_not_found_2.ink`
  - "Compiler e2e: variables/warn_variable_not_found_2.ink" — `src/test/compiler_helpers.zig`

#### `runtime/weaves/`

- `conditional_choice_in_weave.ink`
  - "Compiler e2e: weaves/conditional_choice_in_weave.ink" — `src/test/compiler_helpers.zig`
- `conditional_choice_in_weave_2.ink`
  - "Compiler e2e: weaves/conditional_choice_in_weave_2.ink" — `src/test/compiler_helpers.zig`
- `unbalanced_weave_indentation.ink`
  - "Compiler e2e: weaves/unbalanced_weave_indentation.ink" — `src/test/compiler_helpers.zig`
- `weave_gathers.ink`
  - "Compiler e2e: weave_gathers.ink" — `src/test/compiler_helpers.zig`
- `weave_options.ink`
  - "Compiler e2e: weave_options.ink — start+choice-only+following in knot" — `src/test/compiler_helpers.zig`
- `weave_within_sequence.ink`
  - "Compiler e2e: weaves/weave_within_sequence.ink" — `src/test/compiler_helpers.zig`

## Compiled Fixtures

#### `player/`

- `error_and_exceptions.ink.json`
  - "Player error_and_exceptions" — `src/runtime/story.zig`
- `flow.ink.json`
  - "Player flow" — `src/runtime/story.zig`
- `functions.ink.json`
  - "Player functions" — `src/runtime/story.zig`
- `ink_error.ink.json`
  - "Player ink_error" — `src/runtime/story.zig`
- `ink_list_roundtrip.ink.json`
  - "Player ink_list_roundtrip" — `src/runtime/story.zig`
- `variable_observation.ink.json`
  - "Player variable_observation" — `src/runtime/story.zig`
- `variables.ink.json`
  - "Player variables" — `src/runtime/story.zig`

#### `runtime/bindings/`

- `external_binding.ink.json`
  - "external_binding: bound functions called with correct args" — `src/runtime/story.zig`
- `game_ink_back_and_forth.ink.json`
  - "Story game_ink_back_and_forth" — `src/runtime/story.zig`
- `lookup_safe_or_not.ink.json`
  - "Story lookup_safe_or_not" — `src/runtime/story.zig`
- `lookup_safe_or_not_with_post_glue.ink.json`
  - "Story lookup_safe_or_not_with_post_glue" — `src/runtime/story.zig`
- `variable_observer.ink.json`
  - "variable_observer.ink.json: observer fires during story execution" — `src/runtime/story.zig`

#### `runtime/booleans/`

- `false_plus_false.ink.json`
  - "Story false_plus_false" — `src/runtime/story.zig`
- `list_hasnt.ink.json`
  - "Story list_hasnt" — `src/runtime/story.zig`
- `not_one.ink.json`
  - "Story not_one" — `src/runtime/story.zig`
- `not_true.ink.json`
  - "Story not_true" — `src/runtime/story.zig`
- `three_greater_than_one.ink.json`
  - "Story three_greater_than_one" — `src/runtime/story.zig`
- `true.ink.json`
  - "Story boolean true" — `src/runtime/story.zig`
- `true_equals_one.ink.json`
  - "Story true_equals_one" — `src/runtime/story.zig`
- `true_plus_one.ink.json`
  - "Story true_plus_one" — `src/runtime/story.zig`
- `true_plus_true.ink.json`
  - "Story true_plus_true" — `src/runtime/story.zig`
- `two_plus_true.ink.json`
  - "Story two_plus_true" — `src/runtime/story.zig`

#### `runtime/builtins/`

- `floor_ceiling_and_casts.ink.json`
  - "Story floor_ceiling_and_casts" — `src/runtime/story.zig`
- `read_count_across_callstack.ink.json`
  - "Story read_count_across_callstack" — `src/runtime/story.zig`
- `read_count_across_threads.ink.json`
  - "Story read_count_across_threads" — `src/runtime/story.zig`
- `read_count_dot_separated_path.ink.json`
  - "Story read_count_dot_separated_path" — `src/runtime/story.zig`
- `read_count_variable_target.ink.json`
  - "Story read_count_variable_target" — `src/runtime/story.zig`
- `turns.ink.json`
  - "Story turns (turn_index cycles)" — `src/runtime/story.zig`
- `turns_since.ink.json`
  - "Story turns_since" — `src/runtime/story.zig`
- `turns_since_nested.ink.json`
  - "Story turns_since_nested" — `src/runtime/story.zig`
- `turns_since_with_variable_target.ink.json`
  - "Story turns_since_with_variable_target" — `src/runtime/story.zig`
- `visit_count_bug_due_to_nested_containers.ink.json`
  - "Story visit_count_bug_due_to_nested_containers" — `src/runtime/story.zig`
- `visit_counts_when_choosing.ink.json`
  - "Story visit_counts_when_choosing" — `src/runtime/story.zig`

#### `runtime/callstack/`

- `call_stack_evaluation.ink.json`
  - "Story call_stack_evaluation" — `src/runtime/story.zig`
- `callstack_evaluation.ink.json`
  - "Story callstack_evaluation" — `src/runtime/story.zig`
- `clean_callstack_reset_on_path_choice.ink.json`
  - "Story clean_callstack_reset_on_path_choice" — `src/runtime/story.zig`

#### `runtime/choices/`

- `choice_count.ink.json`
  - "Story choice_count" — `src/runtime/story.zig`
- `choice_diverts_to_done.ink.json`
  - "Story choice_diverts_to_done" — `src/runtime/story.zig`
- `choice_thread_forking.ink.json`
  - "Story choice_thread_forking" — `src/runtime/story.zig`
- `choice_with_brackets_only.ink.json`
  - "choice_with_brackets_only: choice text and selection" — `src/runtime/story.zig`
- `conditional_choices.ink.json`
  - "conditional_choices: only enabled choices visible" — `src/runtime/story.zig`
- `default_choices.ink.json`
  - "default_choices: invisible default auto-follows when no other choices remain" — `src/runtime/story.zig`
- `default_simple_gather.ink.json`
  - "Story default_simple_gather" — `src/runtime/story.zig`
- `fallback_choice_on_thread.ink.json`
  - "Story fallback_choice_on_thread" — `src/runtime/story.zig`
- `gather_choice_same_line.ink.json`
  - "Story gather_choice_same_line" — `src/runtime/story.zig`
- `has_read_on_choice.ink.json`
  - "Story has_read_on_choice" — `src/runtime/story.zig`
- `logic_in_choices.ink.json`
  - "Story logic_in_choices" — `src/runtime/story.zig`
- `non_text_in_choice_inner_content.ink.json`
  - "Story non_text_in_choice_inner_content" — `src/runtime/story.zig`
- `once_only_choices_can_link_back_to_self.ink.json`
  - "once_only_choices_can_link_back_to_self: once-only disappears after selection" — `src/runtime/story.zig`
- `once_only_choices_with_own_content.ink.json`
  - "once_only_choices_with_own_content: choices disappear after selection" — `src/runtime/story.zig`
- `should_not_gather_due_to_choice.ink.json`
  - "Story should_not_gather_due_to_choice" — `src/runtime/story.zig`
- `state_rollback_over_default_choice.ink.json`
  - "Story state_rollback_over_default_choice" — `src/runtime/story.zig`
- `sticky_choices_stay_sticky.ink.json`
  - "sticky_choices_stay_sticky: choices reappear each turn" — `src/runtime/story.zig`
- `various_default_choices.ink.json`
  - "Story various_default_choices" — `src/runtime/story.zig`

#### `runtime/conditions/`

- `all_switch_branches_fail_is_clean.ink.json`
  - "Story all_switch_branches_fail_is_clean" — `src/runtime/story.zig`
- `conditionals.ink.json`
  - "runStory conditionals" — `src/test/helpers.zig`
  - "Story conditionals" — `src/runtime/story.zig`
- `else_branches.ink.json`
  - "runStory else_branches" — `src/test/helpers.zig`
  - "Story else_branches" — `src/runtime/story.zig`
- `empty_multiline_conditional_branch.ink.json`
  - "Story empty_multiline_conditional_branch" — `src/runtime/story.zig`
- `trivial_condition.ink.json`
  - "Story trivial_condition" — `src/runtime/story.zig`

#### `runtime/diverts/`

- `basic_tunnel.ink.json`
  - "runStory basic_tunnel" — `src/test/helpers.zig`
  - "loadStory basic_tunnel named content" — `src/runtime/json_loader.zig`
  - "Container paths basic_tunnel" — `src/runtime/json_loader.zig`
  - "Story basic tunnel" — `src/runtime/story.zig`
  - "resolvePath absolute named container" — `src/runtime/story.zig`
  - "Story basic_tunnel" — `src/runtime/story.zig`
- `compare_divert_targets.ink.json`
  - "Story compare_divert_targets" — `src/runtime/story.zig`
- `complex_tunnels.ink.json`
  - "Story complex_tunnels" — `src/runtime/story.zig`
- `divert_in_conditional.ink.json`
  - "Story divert_in_conditional" — `src/runtime/story.zig`
- `divert_targets_with_parameters.ink.json`
  - "Story divert_targets_with_parameters" — `src/runtime/story.zig`
- `divert_to_weave_points.ink.json`
  - "Story divert_to_weave_points" — `src/runtime/story.zig`
- `done_stops_thread.ink.json`
  - "Story done_stops_thread" — `src/runtime/story.zig`
- `path_to_self.ink.json`
  - "Story path_to_self" — `src/runtime/story.zig`
- `same_line_divert_is_inline.ink.json`
  - "Story same_line_divert_is_inline" — `src/runtime/story.zig`
- `tunnel_onwards_after_tunnel.ink.json`
  - "Story tunnel_onwards_after_tunnel" — `src/runtime/story.zig`
- `tunnel_onwards_divert_after_with_arg.ink.json`
  - "Story tunnel_onwards_divert_after_with_arg" — `src/runtime/story.zig`
- `tunnel_onwards_divert_override.ink.json`
  - "Story tunnel_onwards_divert_override" — `src/runtime/story.zig`
- `tunnel_onwards_to_variable_divert_target.ink.json`
  - "Story tunnel_onwards_to_variable_divert_target" — `src/runtime/story.zig`
- `tunnel_onwards_with_param_default_choice.ink.json`
  - "Story tunnel_onwards_with_param_default_choice" — `src/runtime/story.zig`
- `tunnel_vs_thread_behaviour.ink.json`
  - "Story tunnel_vs_thread_behaviour" — `src/runtime/story.zig`

#### `runtime/evaluation/`

- `arithmetic.ink.json`
  - "runStory arithmetic" — `src/test/helpers.zig`
  - "loadStory arithmetic" — `src/runtime/json_loader.zig`
  - "Story arithmetic" — `src/runtime/story.zig`
- `basic_string_literals.ink.json`
  - "Story basic_string_literals" — `src/runtime/story.zig`
- `evaluating_function_variable_state_bug.ink.json`
  - "Story evaluating_function_variable_state_bug" — `src/runtime/story.zig`
- `evaluating_ink_functions_from_game.ink.json`
  - "Story evaluating_ink_functions_from_game" — `src/runtime/story.zig`
- `evaluating_ink_functions_from_game_2.ink.json`
  - "evaluateFunction: func1 returns int value and captures text" — `src/runtime/story.zig`
  - "evaluateFunction: func2 returns null (void function)" — `src/runtime/story.zig`
  - "evaluateFunction: add(x,y) returns x+y" — `src/runtime/story.zig`
  - "evaluateFunction: story state fully restored after call" — `src/runtime/story.zig`
  - "Story evaluating_ink_functions_from_game_2" — `src/runtime/story.zig`
- `evaluation_stack_leaks.ink.json`
  - "Story evaluation_stack_leaks" — `src/runtime/story.zig`
- `factorial_by_reference.ink.json`
  - "Story factorial_by_reference" — `src/runtime/story.zig`
- `factorial_recursive.ink.json`
  - "runStory factorial_recursive" — `src/test/helpers.zig`
  - "Story factorial recursive" — `src/runtime/story.zig`
- `increment.ink.json`
  - "Story increment" — `src/runtime/story.zig`
- `literal_unary.ink.json`
  - "Story literal_unary" — `src/runtime/story.zig`

#### `runtime/extra/`

- `arithmetic_2.ink.json`
  - "Story arithmetic_2" — `src/runtime/story.zig`
- `list_comparison.ink.json`
  - "Story list_comparison" — `src/runtime/story.zig`

#### `runtime/glue/`

- `implicit_inline_glue.ink.json`
  - "Story implicit_inline_glue" — `src/runtime/story.zig`
- `implicit_inline_glue_b.ink.json`
  - "Story implicit_inline_glue_b" — `src/runtime/story.zig`
- `implicit_inline_glue_c.ink.json`
  - "Story implicit_inline_glue_c" — `src/runtime/story.zig`
- `left_right_glue_matching.ink.json`
  - "Story left_right_glue_matching" — `src/runtime/story.zig`
- `simple_glue.ink.json`
  - "Story simple_glue" — `src/runtime/story.zig`

#### `runtime/knots/`

- `knot_do_not_gather.ink.json`
  - "Story knot_do_not_gather" — `src/runtime/story.zig`
- `knot_stitch_gather_counts.ink.json`
  - "knot_stitch_gather_counts: visit counts tracked per knot and stitch" — `src/runtime/story.zig`
  - "visitCountAtPathString: 0 before visit, 1 after" — `src/runtime/story.zig`
- `knot_thread_interaction.ink.json`
  - "Story knot_thread_interaction" — `src/runtime/story.zig`
- `knot_thread_interaction_2.ink.json`
  - "Story knot_thread_interaction_2" — `src/runtime/story.zig`

#### `runtime/lists/`

- `contains_empty_list_always_false.ink.json`
  - "Story contains_empty_list_always_false" — `src/runtime/story.zig`
- `empty_list_origin.ink.json`
  - "Story empty_list_origin" — `src/runtime/story.zig`
- `empty_list_origin_after_assignment.ink.json`
  - "Story empty_list_origin_after_assignment" — `src/runtime/story.zig`
- `list_basic_operations.ink.json`
  - "runStory list_basic_operations" — `src/test/helpers.zig`
  - "loadStory list_basic_operations listDefs" — `src/runtime/json_loader.zig`
  - "list_basic_operations: union, intersect, has, hasnt" — `src/runtime/story.zig`
  - "Story list_basic_operations" — `src/runtime/story.zig`
  - "ListDefinitionsOrigin.parse from list_basic_operations" — `src/runtime/lists.zig`
- `list_mixed_items.ink.json`
  - "list_mixed_items: multi-origin list union" — `src/runtime/story.zig`
  - "Story list_mixed_items" — `src/runtime/story.zig`
- `list_random.ink.json`
  - "Story list_random" — `src/runtime/story.zig`
- `list_range.ink.json`
  - "list_range: range control command and LIST_ALL with origins" — `src/runtime/story.zig`
  - "Story list_range" — `src/runtime/story.zig`
- `list_save_load.ink.json`
  - "save/load round-trip: list variables preserved across list_save_load" — `src/runtime/story.zig`
  - "Story list_save_load" — `src/runtime/story.zig`
- `more_list_operations.ink.json`
  - "more_list_operations: LIST_VALUE, listInt, LIST_ALL, LIST_INVERT" — `src/runtime/story.zig`
  - "Story more_list_operations" — `src/runtime/story.zig`

#### `runtime/logic/`

- `logic_lines_with_newlines.ink.json`
  - "runStory logic_lines_with_newlines" — `src/test/helpers.zig`
  - "Story logic_lines_with_newlines" — `src/runtime/story.zig`
- `multiline_logic_with_glue.ink.json`
  - "Story multiline_logic_with_glue" — `src/runtime/story.zig`
- `nested_pass_by_reference.ink.json`
  - "Story nested_pass_by_reference" — `src/runtime/story.zig`
- `print_num.ink.json`
  - "Story print_num" — `src/runtime/story.zig`

#### `runtime/misc/`

- `empty.ink.json`
  - "Story empty" — `src/runtime/story.zig`
- `end.ink.json`
  - "Story end" — `src/runtime/story.zig`
- `end2.ink.json`
  - "Story end2" — `src/runtime/story.zig`
- `end_of_content.ink.json`
  - "Story end_of_content" — `src/runtime/story.zig`
- `escape_character.ink.json`
  - "Story escape_character" — `src/runtime/story.zig`
- `hello_world.ink.json`
  - "loadFixture returns non-empty slice" — `src/test/helpers.zig`
  - "runStory hello_world" — `src/test/helpers.zig`
  - "loadStory hello_world" — `src/runtime/json_loader.zig`
  - "Container paths hello_world" — `src/runtime/json_loader.zig`
  - "Story hello_world" — `src/runtime/story.zig`
  - "Temp var found in function frame" — `src/runtime/story.zig`
  - "Temp var shadows global; global restored after pop" — `src/runtime/story.zig`
  - "resolvePath relative with ^ traverses parent" — `src/runtime/story.zig`
  - "resolvePath non-existent returns null" — `src/runtime/story.zig`
  - "str/str collects strings onto eval stack" — `src/runtime/story.zig`
  - "turns_since returns -1 for never-visited path" — `src/runtime/story.zig`
  - "srnd sets story_seed" — `src/runtime/story.zig`
  - "toJson: fresh state contains required top-level keys" — `src/runtime/story.zig`
  - "save/load round-trip: hello_world pointer preserved" — `src/runtime/story.zig`
  - "observeVariable: fires when observed global changes" — `src/runtime/story.zig`
  - "observeVariable: does not fire for unobserved variable" — `src/runtime/story.zig`
  - "currentFlowIsDefaultFlow: true initially, false after switchFlow" — `src/runtime/story.zig`
- `identifiers_can_start_with_number.ink.json`
  - "Story identifiers_can_start_with_number" — `src/runtime/story.zig`
- `include.ink.json`
  - "Story include" — `src/runtime/story.zig`
- `nested_include.ink.json`
  - "Story nested_include" — `src/runtime/story.zig`
- `quote_character_significance.ink.json`
  - "Story quote_character_significance" — `src/runtime/story.zig`
- `whitespace.ink.json`
  - "Story whitespace" — `src/runtime/story.zig`

#### `runtime/misc/includes/`

- `included_file.ink.json`
  - Unused in direct unit tests
- `included_file_2.ink.json`
  - Unused in direct unit tests
- `included_file_4.ink.json`
  - Unused in direct unit tests

#### `runtime/multiflow/`

- `multi_flow_basics.ink.json`
  - "multi_flow_basics: separate flow states maintained" — `src/runtime/story.zig`
- `multi_flow_save_load_threads.ink.json`
  - "Story multi_flow_save_load_threads" — `src/runtime/story.zig`

#### `runtime/newlines/`

- `newline_at_start_of_multiline_conditional.ink.json`
  - "Story newline_at_start_of_multiline_conditional" — `src/runtime/story.zig`
- `newline_consistency_1.ink.json`
  - "Story newline_consistency_1" — `src/runtime/story.zig`
- `newline_consistency_2.ink.json`
  - "Story newline_consistency_2" — `src/runtime/story.zig`
- `newline_consistency_3.ink.json`
  - "Story newline_consistency_3" — `src/runtime/story.zig`
- `newlines_trimming_with_func_external_fallback.ink.json`
  - "Story newlines_trimming_with_func_external_fallback" — `src/runtime/story.zig`
- `newlines_with_string_eval.ink.json`
  - "Story newlines_with_string_eval" — `src/runtime/story.zig`

#### `runtime/sequences/`

- `all_sequence_types.ink.json`
  - "Stopping sequence clamps at last item" — `src/runtime/story.zig`
  - "Cycle sequence wraps correctly" — `src/runtime/story.zig`
  - "Story all_sequence_types" — `src/runtime/story.zig`
- `blanks_in_inline_sequences.ink.json`
  - "Story blanks_in_inline_sequences" — `src/runtime/story.zig`
- `empty_sequence_content.ink.json`
  - "Story empty_sequence_content" — `src/runtime/story.zig`
- `gather_read_count_with_initial_sequence.ink.json`
  - "Story gather_read_count_with_initial_sequence" — `src/runtime/story.zig`
- `leading_newline_multiline_sequence.ink.json`
  - "Story leading_newline_multiline_sequence" — `src/runtime/story.zig`
- `shuffle_stack_muddying.ink.json`
  - "Story shuffle_stack_muddying" — `src/runtime/story.zig`

#### `runtime/strings/`

- `string_constants.ink.json`
  - "Story string_constants" — `src/runtime/story.zig`
- `string_contains.ink.json`
  - "Story string_contains" — `src/runtime/story.zig`
- `string_type_coercion.ink.json`
  - "Story string_type_coercion" — `src/runtime/story.zig`
- `strings_in_choices.ink.json`
  - "Story strings_in_choices" — `src/runtime/story.zig`

#### `runtime/tags/`

- `tags.ink.json`
  - "tags: start_tag/end_tag collects tag strings; content still output" — `src/runtime/story.zig`
  - "choosePathString: jumps to named knot" — `src/runtime/story.zig`
  - "globalTags: returns story-level tags from tags.ink.json" — `src/runtime/story.zig`
- `tags_dynamic_content.ink.json`
  - "Story tags_dynamic_content" — `src/runtime/story.zig`
- `tags_in_choice.ink.json`
  - "Story tags_in_choice" — `src/runtime/story.zig`
- `tags_in_seq.ink.json`
  - "Story tags_in_seq" — `src/runtime/story.zig`
- `tags_on_choice.ink.json`
  - "Story tags_on_choice" — `src/runtime/story.zig`

#### `runtime/threads/`

- `multi_thread.ink.json`
  - "multi_thread: choices from both threads merged" — `src/runtime/story.zig`
- `thread_done.ink.json`
  - "thread_done: forked thread ends with done, main continues" — `src/runtime/story.zig`
- `thread_in_logic.ink.json`
  - "Story thread_in_logic" — `src/runtime/story.zig`
- `top_flow_terminator_should_not_kill_thread_choices.ink.json`
  - "Story top_flow_terminator_should_not_kill_thread_choices" — `src/runtime/story.zig`

#### `runtime/variables/`

- `const.ink.json`
  - "Container paths global decl" — `src/runtime/json_loader.zig`
  - "Story const variable" — `src/runtime/story.zig`
- `multiple_constant_references.ink.json`
  - "Story multiple_constant_references" — `src/runtime/story.zig`
- `set_non_existant_variable.ink.json`
  - "Story set_non_existant_variable" — `src/runtime/story.zig`
- `temp_global_conflict.ink.json`
  - "Story temp_global_conflict" — `src/runtime/story.zig`
- `temp_not_found.ink.json`
  - "Story temp_not_found" — `src/runtime/story.zig`
- `temp_usage_in_options.ink.json`
  - "Story temp_usage_in_options" — `src/runtime/story.zig`
- `temporaries_at_global_scope.ink.json`
  - "Story temporaries_at_global_scope" — `src/runtime/story.zig`
- `variable_declaration_in_conditional.ink.json`
  - "Story variable_declaration_in_conditional" — `src/runtime/story.zig`
- `variable_divert_target.ink.json`
  - "Story variable_divert_target" — `src/runtime/story.zig`
  - "turn_indices updated when entering flagged container" — `src/runtime/story.zig`
- `variable_get_set_api.ink.json`
  - "Story variable_get_set_api" — `src/runtime/story.zig`
- `variable_pointer_ref_from_knot.ink.json`
  - "Story variable_pointer_ref_from_knot" — `src/runtime/story.zig`
- `variable_swap_recurse.ink.json`
  - "Story variable_swap_recurse" — `src/runtime/story.zig`
- `variable_tunnel.ink.json`
  - "Story variable_tunnel" — `src/runtime/story.zig`
- `warn_variable_not_found_1.ink.json`
  - "Story warn_variable_not_found_1" — `src/runtime/story.zig`
- `warn_variable_not_found_2.ink.json`
  - "Story warn_variable_not_found_2" — `src/runtime/story.zig`

#### `runtime/weaves/`

- `conditional_choice_in_weave.ink.json`
  - "Story conditional_choice_in_weave" — `src/runtime/story.zig`
- `conditional_choice_in_weave_2.ink.json`
  - "Story conditional_choice_in_weave_2" — `src/runtime/story.zig`
- `unbalanced_weave_indentation.ink.json`
  - "Story unbalanced_weave_indentation" — `src/runtime/story.zig`
- `weave_gathers.ink.json`
  - "runStory weave_gathers choice path one" — `src/test/helpers.zig`
  - "runStory weave_gathers choice path four" — `src/test/helpers.zig`
  - "Story weave_gathers" — `src/runtime/story.zig`
- `weave_options.ink.json`
  - "Story weave_options" — `src/runtime/story.zig`
- `weave_within_sequence.ink.json`
  - "Story weave_within_sequence" — `src/runtime/story.zig`

## Auxiliary Compiled Files

- `player/error_and_exceptions.ink.json.import`
  - Unused in direct unit tests
- `player/flow.ink.json.import`
  - Unused in direct unit tests
- `player/functions.ink.json.import`
  - Unused in direct unit tests
- `player/ink_error.ink.json.import`
  - Unused in direct unit tests
- `player/ink_list_roundtrip.ink.json.import`
  - Unused in direct unit tests
- `player/variable_observation.ink.json.import`
  - Unused in direct unit tests
- `player/variables.ink.json.import`
  - Unused in direct unit tests

## Unused Original Fixtures

- `runtime/booleans/true_equals_one.ink`
- `runtime/booleans/true_plus_one.ink`
- `runtime/booleans/true_plus_true.ink`
- `runtime/booleans/two_plus_true.ink`
- `runtime/builtins/read_count_variable_target.ink`
- `runtime/builtins/turns_since_with_variable_target.ink`
- `runtime/builtins/visit_counts_when_choosing.ink`
- `runtime/choices/choice_thread_forking.ink`
- `runtime/choices/fallback_choice_on_thread.ink`
- `runtime/evaluation/evaluating_ink_functions_from_game.ink`
- `runtime/evaluation/evaluating_ink_functions_from_game_2.ink`
- `runtime/lists/contains_empty_list_always_false.ink`
- `runtime/lists/empty_list_origin_after_assignment.ink`
- `runtime/lists/list_mixed_items.ink`
- `runtime/lists/list_random.ink`
- `runtime/lists/list_range.ink`
- `runtime/lists/list_save_load.ink`
- `runtime/misc/includes/included_file.ink`
- `runtime/misc/includes/included_file_2.ink`
- `runtime/misc/includes/included_file_3.ink`
- `runtime/misc/includes/included_file_4.ink`
- `runtime/misc/nested_include.ink`
- `runtime/multiflow/multi_flow_basics.ink`
- `runtime/multiflow/multi_flow_save_load_threads.ink`
- `runtime/newlines/newlines_trimming_with_func_external_fallback.ink`
- `runtime/strings/string_contains.ink`

## Unused Compiled Fixtures

- `runtime/misc/includes/included_file.ink.json`
- `runtime/misc/includes/included_file_2.ink.json`
- `runtime/misc/includes/included_file_4.ink.json`
