## ## Original fixtures

### 26 directories, 169 files

test/fixture/original/
├── player
│   ├── error_and_exceptions.ink
│   ├── flow.ink
│   ├── functions.ink
│   ├── ink_error.ink
│   ├── ink_list_roundtrip.ink
│   ├── variable_observation.ink
│   └── variables.ink
└── runtime
 ├── bindings
 │   ├── external_binding.ink
 │   ├── game_ink_back_and_forth.ink
 │   ├── lookup_safe_or_not_with_post_glue.ink
 │   ├── lookup_safe_or_not.ink
 │   └── variable_observer.ink
 ├── booleans
 │   ├── false_plus_false.ink
 │   ├── list_hasnt.ink
 │   ├── not_one.ink
 │   ├── not_true.ink
 │   ├── three_greater_than_one.ink
 │   ├── true_equals_one.ink
 │   ├── true_plus_one.ink
 │   ├── true_plus_true.ink
 │   ├── true.ink
 │   └── two_plus_true.ink
 ├── builtins
 │   ├── floor_ceiling_and_casts.ink
 │   ├── read_count_across_callstack.ink
 │   ├── read_count_across_threads.ink
 │   ├── read_count_dot_separated_path.ink
 │   ├── read_count_variable_target.ink
 │   ├── turns_since_nested.ink
 │   ├── turns_since_with_variable_target.ink
 │   ├── turns_since.ink
 │   ├── turns.ink
 │   ├── visit_count_bug_due_to_nested_containers.ink
 │   └── visit_counts_when_choosing.ink
 ├── callstack
 │   ├── callstack_evaluation.ink
 │   └── clean_callstack_reset_on_path_choice.ink
 ├── choices
 │   ├── choice_count.ink
 │   ├── choice_diverts_to_done.ink
 │   ├── choice_thread_forking.ink
 │   ├── choice_with_brackets_only.ink
 │   ├── conditional_choices.ink
 │   ├── default_choices.ink
 │   ├── default_simple_gather.ink
 │   ├── fallback_choice_on_thread.ink
 │   ├── gather_choice_same_line.ink
 │   ├── has_read_on_choice.ink
 │   ├── logic_in_choices.ink
 │   ├── non_text_in_choice_inner_content.ink
 │   ├── once_only_choices_can_link_back_to_self.ink
 │   ├── once_only_choices_with_own_content.ink
 │   ├── should_not_gather_due_to_choice.ink
 │   ├── state_rollback_over_default_choice.ink
 │   ├── sticky_choices_stay_sticky.ink
 │   └── various_default_choices.ink
 ├── conditions
 │   ├── all_switch_branches_fail_is_clean.ink
 │   ├── conditionals.ink
 │   ├── else_branches.ink
 │   ├── empty_multiline_conditional_branch.ink
 │   └── trivial_condition.ink
 ├── diverts
 │   ├── basic_tunnel.ink
 │   ├── compare_divert_targets.ink
 │   ├── complex_tunnels.ink
 │   ├── divert_in_conditional.ink
 │   ├── divert_targets_with_parameters.ink
 │   ├── divert_to_weave_points.ink
 │   ├── done_stops_thread.ink
 │   ├── path_to_self.ink
 │   ├── same_line_divert_is_inline.ink
 │   ├── tunnel_onwards_after_tunnel.ink
 │   ├── tunnel_onwards_divert_after_with_arg.ink
 │   ├── tunnel_onwards_divert_override.ink
 │   ├── tunnel_onwards_to_variable_divert_target.ink
 │   ├── tunnel_onwards_with_param_default_choice.ink
 │   └── tunnel_vs_thread_behaviour.ink
 ├── evaluation
 │   ├── arithmetic.ink
 │   ├── basic_string_literals.ink
 │   ├── evaluating_function_variable_state_bug.ink
 │   ├── evaluating_ink_functions_from_game_2.ink
 │   ├── evaluating_ink_functions_from_game.ink
 │   ├── evaluation_stack_leaks.ink
 │   ├── factorial_by_reference.ink
 │   ├── factorial_recursive.ink
 │   ├── increment.ink
 │   └── literal_unary.ink
 ├── extra
 │   ├── arithmetic_2.ink
 │   └── list_comparison.ink
 ├── glue
 │   ├── implicit_inline_glue_b.ink
 │   ├── implicit_inline_glue_c.ink
 │   ├── implicit_inline_glue.ink
 │   ├── left_right_glue_matching.ink
 │   └── simple_glue.ink
 ├── knots
 │   ├── knot_do_not_gather.ink
 │   ├── knot_stitch_gather_counts.ink
 │   ├── knot_thread_interaction_2.ink
 │   └── knot_thread_interaction.ink
 ├── lists
 │   ├── contains_empty_list_always_false.ink
 │   ├── empty_list_origin_after_assignment.ink
 │   ├── empty_list_origin.ink
 │   ├── list_basic_operations.ink
 │   ├── list_mixed_items.ink
 │   ├── list_random.ink
 │   ├── list_range.ink
 │   ├── list_save_load.ink
 │   └── more_list_operations.ink
 ├── logic
 │   ├── logic_lines_with_newlines.ink
 │   ├── multiline_logic_with_glue.ink
 │   ├── nested_pass_by_reference.ink
 │   └── print_num.ink
 ├── misc
 │   ├── empty.ink
 │   ├── end_of_content.ink
 │   ├── end.ink
 │   ├── end2.ink
 │   ├── escape_character.ink
 │   ├── hello_world.ink
 │   ├── identifiers_can_start_with_number.ink
 │   ├── include.ink
 │   ├── includes
 │   │   ├── included_file_2.ink
 │   │   ├── included_file_3.ink
 │   │   ├── included_file_4.ink
 │   │   └── included_file.ink
 │   ├── nested_include.ink
 │   ├── quote_character_significance.ink
 │   └── whitespace.ink
 ├── multiflow
 │   ├── multi_flow_basics.ink
 │   └── multi_flow_save_load_threads.ink
 ├── newlines
 │   ├── newline_at_start_of_multiline_conditional.ink
 │   ├── newline_consistency_1.ink
 │   ├── newline_consistency_2.ink
 │   ├── newline_consistency_3.ink
 │   ├── newlines_trimming_with_func_external_fallback.ink
 │   └── newlines_with_string_eval.ink
 ├── sequences
 │   ├── all_sequence_types.ink
 │   ├── blanks_in_inline_sequences.ink
 │   ├── empty_sequence_content.ink

│   ├── gather_read_count_with_initial_sequence.ink
 │   ├── leading_newline_multiline_sequence.ink
 │   └── shuffle_stack_muddying.ink
 ├── strings
 │   ├── string_constants.ink
 │   ├── string_contains.ink
 │   ├── string_type_coercion.ink
 │   └── strings_in_choices.ink
 ├── tags
 │   ├── tags_dynamic_content.ink
 │   ├── tags_in_choice.ink
 │   ├── tags_in_seq.ink
 │   └── tags.ink
 ├── threads
 │   ├── multi_thread.ink
 │   ├── thread_done.ink
 │   ├── thread_in_logic.ink
 │   └── top_flow_terminator_should_not_kill_thread_choices.ink
 ├── variables
 │   ├── const.ink
 │   ├── multiple_constant_references.ink
 │   ├── set_non_existant_variable.ink
 │   ├── temp_global_conflict.ink
 │   ├── temp_not_found.ink
 │   ├── temp_usage_in_options.ink
 │   ├── temporaries_at_global_scope.ink
 │   ├── variable_declaration_in_conditional.ink
 │   ├── variable_divert_target.ink
 │   ├── variable_get_set_api.ink
 │   ├── variable_pointer_ref_from_knot.ink
 │   ├── variable_swap_recurse.ink
 │   ├── variable_tunnel.ink
 │   ├── warn_variable_not_found_1.ink
 │   └── warn_variable_not_found_2.ink
 └── weaves
 ├── conditional_choice_in_weave_2.ink
 ├── conditional_choice_in_weave.ink
 ├── unbalanced_weave_indentation.ink
 ├── weave_gathers.ink
 ├── weave_options.ink
 └── weave_within_sequence.ink

## Compiled fixtures

### 26 directories, 177 files

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
- `turns_since.ink.json`
  - "Story turns_since" — `src/runtime/story.zig`
- `turns_since_nested.ink.json`
  - "Story turns_since_nested" — `src/runtime/story.zig`
- `turns_since_with_variable_target.ink.json`
  - "Story turns_since_with_variable_target" — `src/runtime/story.zig`
- `turns.ink.json`
  - "Story turns (turn_index cycles)" — `src/runtime/story.zig`
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
  - "Story conditionals" — `src/runtime/story.zig`
  - "runStory conditionals" — `src/test/helpers.zig`
- `else_branches.ink.json`
  - "Story else_branches" — `src/runtime/story.zig`
  - "runStory else_branches" — `src/test/helpers.zig`
- `empty_multiline_conditional_branch.ink.json`
  - "Story empty_multiline_conditional_branch" — `src/runtime/story.zig`
- `trivial_condition.ink.json`
  - "Story trivial_condition" — `src/runtime/story.zig`

#### `runtime/diverts/`

- `basic_tunnel.ink.json`
  - "Story basic tunnel" — `src/runtime/story.zig`
  - "Story basic_tunnel" — `src/runtime/story.zig`
  - "resolvePath absolute named container" — `src/runtime/story.zig`
  - "runStory basic_tunnel" — `src/test/helpers.zig`
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
  - "Story arithmetic" — `src/runtime/story.zig`
  - "runStory arithmetic" — `src/test/helpers.zig`
- `basic_string_literals.ink.json`
  - "Story basic_string_literals" — `src/runtime/story.zig`
- `evaluating_function_variable_state_bug.ink.json`
  - "Story evaluating_function_variable_state_bug" — `src/runtime/story.zig`
- `evaluating_ink_functions_from_game.ink.json`
  - "Story evaluating_ink_functions_from_game" — `src/runtime/story.zig`
- `evaluating_ink_functions_from_game_2.ink.json`
  - "Story evaluating_ink_functions_from_game_2" — `src/runtime/story.zig`
  - "evaluateFunction: func1 returns int value and captures text" — `src/runtime/story.zig`
  - "evaluateFunction: func2 returns null (void function)" — `src/runtime/story.zig`
  - "evaluateFunction: add(x,y) returns x+y" — `src/runtime/story.zig`
  - "evaluateFunction: story state fully restored after call" — `src/runtime/story.zig`
- `evaluation_stack_leaks.ink.json`
  - "Story evaluation_stack_leaks" — `src/runtime/story.zig`
- `factorial_by_reference.ink.json`
  - "Story factorial_by_reference" — `src/runtime/story.zig`
- `factorial_recursive.ink.json`
  - "Story factorial recursive" — `src/runtime/story.zig`
  - "runStory factorial_recursive" — `src/test/helpers.zig`
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
  - "list_basic_operations: union, intersect, has, hasnt" — `src/runtime/story.zig`
  - "Story list_basic_operations" — `src/runtime/story.zig`
  - "runStory list_basic_operations" — `src/test/helpers.zig`
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
  - "Story logic_lines_with_newlines" — `src/runtime/story.zig`
  - "runStory logic_lines_with_newlines" — `src/test/helpers.zig`
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
  - "Story hello_world" — `src/runtime/story.zig`
  - "Temp var found in function frame" — `src/runtime/story.zig`
  - "Temp var shadows global; global restored after pop" — `src/runtime/story.zig`
  - "currentFlowIsDefaultFlow: true initially, false after switchFlow" — `src/runtime/story.zig`
  - "observeVariable: does not fire for unobserved variable" — `src/runtime/story.zig`
  - "observeVariable: fires when observed global changes" — `src/runtime/story.zig`
  - "resolvePath non-existent returns null" — `src/runtime/story.zig`
  - "resolvePath relative with ^ traverses parent" — `src/runtime/story.zig`
  - "save/load round-trip: hello_world pointer preserved" — `src/runtime/story.zig`
  - "srnd sets story_seed" — `src/runtime/story.zig`
  - "str/str collects strings onto eval stack" — `src/runtime/story.zig`
  - "toJson: fresh state contains required top-level keys" — `src/runtime/story.zig`
  - "turns_since returns -1 for never-visited path" — `src/runtime/story.zig`
  - "loadFixture returns non-empty slice" — `src/test/helpers.zig`
  - "runStory hello_world" — `src/test/helpers.zig`
- `identifiers_can_start_with_number.ink.json`
  - "Story identifiers_can_start_with_number" — `src/runtime/story.zig`
- `include.ink.json`
  - "Story include" — `src/runtime/story.zig`
- `includes/included_file.ink.json` *(loaded transitively by `include.ink.json` and `nested_include.ink.json`)*
- `includes/included_file_2.ink.json` *(loaded transitively by `nested_include.ink.json`)*
- `includes/included_file_4.ink.json` *(loaded transitively by `nested_include.ink.json`)*
- `nested_include.ink.json`
  - "Story nested_include" — `src/runtime/story.zig`
- `quote_character_significance.ink.json`
  - "Story quote_character_significance" — `src/runtime/story.zig`
- `whitespace.ink.json`
  - "Story whitespace" — `src/runtime/story.zig`

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
  - "Story weave_gathers" — `src/runtime/story.zig`
  - "runStory weave_gathers choice path one" — `src/test/helpers.zig`
  - "runStory weave_gathers choice path four" — `src/test/helpers.zig`
- `weave_options.ink.json`
  - "Story weave_options" — `src/runtime/story.zig`
- `weave_within_sequence.ink.json`
  - "Story weave_within_sequence" — `src/runtime/story.zig`
