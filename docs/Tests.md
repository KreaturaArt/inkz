## Compiled fixtures

### 26 directories, 177 files

#### `player/`

- `error_and_exceptions.ink.json`
  - "Player error_and_exceptions" — `src/runtime/story.zig:5066`
- `flow.ink.json`
  - "Player flow" — `src/runtime/story.zig:4997`
- `functions.ink.json`
  - "Player functions" — `src/runtime/story.zig:5026`
- `ink_error.ink.json`
  - "Player ink_error" — `src/runtime/story.zig:5079`
- `ink_list_roundtrip.ink.json`
  - "Player ink_list_roundtrip" — `src/runtime/story.zig:5040`
- `variable_observation.ink.json`
  - "Player variable_observation" — `src/runtime/story.zig:5052`
- `variables.ink.json`
  - "Player variables" — `src/runtime/story.zig:5013`

#### `runtime/bindings/`

- `external_binding.ink.json`
  - "external_binding: bound functions called with correct args" — `src/runtime/story.zig:3388`
- `game_ink_back_and_forth.ink.json`
  - "Story game_ink_back_and_forth" — `src/runtime/story.zig:4932`
- `lookup_safe_or_not.ink.json`
  - "Story lookup_safe_or_not" — `src/runtime/story.zig:4948`
- `lookup_safe_or_not_with_post_glue.ink.json`
  - "Story lookup_safe_or_not_with_post_glue" — `src/runtime/story.zig:4962`
- `variable_observer.ink.json`
  - "variable_observer.ink.json: observer fires during story execution" — `src/runtime/story.zig:3529`

#### `runtime/booleans/`

- `false_plus_false.ink.json`
  - "Story false_plus_false" — `src/runtime/story.zig:2167`
- `list_hasnt.ink.json`
  - "Story list_hasnt" — `src/runtime/story.zig:2222`
- `not_one.ink.json`
  - "Story not_one" — `src/runtime/story.zig:2178`
- `not_true.ink.json`
  - "Story not_true" — `src/runtime/story.zig:2128`
- `three_greater_than_one.ink.json`
  - "Story three_greater_than_one" — `src/runtime/story.zig:2141`
- `true.ink.json`
  - "Story boolean true" — `src/runtime/story.zig:2076`
- `true_equals_one.ink.json`
  - "Story true_equals_one" — `src/runtime/story.zig:2189`
- `true_plus_one.ink.json`
  - "Story true_plus_one" — `src/runtime/story.zig:2200`
- `true_plus_true.ink.json`
  - "Story true_plus_true" — `src/runtime/story.zig:2154`
- `two_plus_true.ink.json`
  - "Story two_plus_true" — `src/runtime/story.zig:2211`

#### `runtime/builtins/`

- `floor_ceiling_and_casts.ink.json`
  - "Story floor_ceiling_and_casts" — `src/runtime/story.zig:2403`
- `read_count_across_callstack.ink.json`
  - "Story read_count_across_callstack" — `src/runtime/story.zig:2506`
- `read_count_across_threads.ink.json`
  - "Story read_count_across_threads" — `src/runtime/story.zig:2547`
- `read_count_dot_separated_path.ink.json`
  - "Story read_count_dot_separated_path" — `src/runtime/story.zig:2523`
- `read_count_variable_target.ink.json`
  - "Story read_count_variable_target" — `src/runtime/story.zig:2535`
- `turns_since.ink.json`
- `turns_since_nested.ink.json`
  - "Story turns_since_nested" — `src/runtime/story.zig:2561`
- `turns_since_with_variable_target.ink.json`
  - "Story turns_since_with_variable_target" — `src/runtime/story.zig:2589`
- `turns.ink.json`
  - "Story turns (turn_index cycles)" — `src/runtime/story.zig:2610`
- `visit_count_bug_due_to_nested_containers.ink.json`
  - "Story visit_count_bug_due_to_nested_containers" — `src/runtime/story.zig:2631`
- `visit_counts_when_choosing.ink.json`
  - "Story visit_counts_when_choosing" — `src/runtime/story.zig:2652`

#### `runtime/callstack/`

- `call_stack_evaluation.ink.json`
  - "Story call_stack_evaluation" — `src/runtime/story.zig:2321`
- `callstack_evaluation.ink.json`
  - "Story callstack_evaluation" — `src/runtime/story.zig:2307`
- `clean_callstack_reset_on_path_choice.ink.json`
  - "Story clean_callstack_reset_on_path_choice" — `src/runtime/story.zig:2333`

#### `runtime/choices/`

- `choice_count.ink.json`
  - "Story choice_count" — `src/runtime/story.zig:2893`
- `choice_diverts_to_done.ink.json`
  - "Story choice_diverts_to_done" — `src/runtime/story.zig:2906`
- `choice_thread_forking.ink.json`
  - "Story choice_thread_forking" — `src/runtime/story.zig:2925`
- `choice_with_brackets_only.ink.json`
  - "choice_with_brackets_only: choice text and selection" — `src/runtime/story.zig:2743`
- `conditional_choices.ink.json`
  - "conditional_choices: only enabled choices visible" — `src/runtime/story.zig:2859`
- `default_choices.ink.json`
  - "default_choices: invisible default auto-follows when no other choices remain" — `src/runtime/story.zig:2832`
- `default_simple_gather.ink.json`
  - "Story default_simple_gather" — `src/runtime/story.zig:2947`
- `fallback_choice_on_thread.ink.json`
  - "Story fallback_choice_on_thread" — `src/runtime/story.zig:2960`
- `gather_choice_same_line.ink.json`
  - "Story gather_choice_same_line" — `src/runtime/story.zig:2975`
- `has_read_on_choice.ink.json`
  - "Story has_read_on_choice" — `src/runtime/story.zig:3000`
- `logic_in_choices.ink.json`
  - "Story logic_in_choices" — `src/runtime/story.zig:3018`
- `non_text_in_choice_inner_content.ink.json`
  - "Story non_text_in_choice_inner_content" — `src/runtime/story.zig:3036`
- `once_only_choices_can_link_back_to_self.ink.json`
  - "once_only_choices_can_link_back_to_self: once-only disappears after selection" — `src/runtime/story.zig:2760`
- `once_only_choices_with_own_content.ink.json`
  - "once_only_choices_with_own_content: choices disappear after selection" — `src/runtime/story.zig:2810`
- `should_not_gather_due_to_choice.ink.json`
  - "Story should_not_gather_due_to_choice" — `src/runtime/story.zig:3055`
- `state_rollback_over_default_choice.ink.json`
  - "Story state_rollback_over_default_choice" — `src/runtime/story.zig:3073`
- `sticky_choices_stay_sticky.ink.json`
  - "sticky_choices_stay_sticky: choices reappear each turn" — `src/runtime/story.zig:2787`
- `various_default_choices.ink.json`
  - "Story various_default_choices" — `src/runtime/story.zig:3087`

#### `runtime/conditions/`

- `all_switch_branches_fail_is_clean.ink.json`
  - "Story all_switch_branches_fail_is_clean" — `src/runtime/story.zig:3104`
- `conditionals.ink.json`
  - "Story conditionals" — `src/runtime/story.zig:3117`
  - "runStory conditionals" — `src/test/helpers.zig:69`
- `else_branches.ink.json`
  - "Story else_branches" — `src/runtime/story.zig:3132`
  - "runStory else_branches" — `src/test/helpers.zig:79`
- `empty_multiline_conditional_branch.ink.json`
  - "Story empty_multiline_conditional_branch" — `src/runtime/story.zig:3147`
- `trivial_condition.ink.json`
  - "Story trivial_condition" — `src/runtime/story.zig:3160`

#### `runtime/diverts/`

- `basic_tunnel.ink.json`
  - "Story basic tunnel" — `src/runtime/story.zig:2115`
  - "Story basic_tunnel" — `src/runtime/story.zig:3685`
  - "resolvePath absolute named container" — `src/runtime/story.zig:2352`
  - "runStory basic_tunnel" — `src/test/helpers.zig:140`
- `compare_divert_targets.ink.json`
  - "Story compare_divert_targets" — `src/runtime/story.zig:3699`
- `complex_tunnels.ink.json`
  - "Story complex_tunnels" — `src/runtime/story.zig:2489`
- `divert_in_conditional.ink.json`
  - "Story divert_in_conditional" — `src/runtime/story.zig:3715`
- `divert_targets_with_parameters.ink.json`
  - "Story divert_targets_with_parameters" — `src/runtime/story.zig:2463`
- `divert_to_weave_points.ink.json`
  - "Story divert_to_weave_points" — `src/runtime/story.zig:3731`
- `done_stops_thread.ink.json`
  - "Story done_stops_thread" — `src/runtime/story.zig:3743`
- `path_to_self.ink.json`
  - "Story path_to_self" — `src/runtime/story.zig:3756`
- `same_line_divert_is_inline.ink.json`
  - "Story same_line_divert_is_inline" — `src/runtime/story.zig:2390`
- `tunnel_onwards_after_tunnel.ink.json`
  - "Story tunnel_onwards_after_tunnel" — `src/runtime/story.zig:3774`
- `tunnel_onwards_divert_after_with_arg.ink.json`
  - "Story tunnel_onwards_divert_after_with_arg" — `src/runtime/story.zig:3789`
- `tunnel_onwards_divert_override.ink.json`
  - "Story tunnel_onwards_divert_override" — `src/runtime/story.zig:3802`
- `tunnel_onwards_to_variable_divert_target.ink.json`
  - "Story tunnel_onwards_to_variable_divert_target" — `src/runtime/story.zig:3817`
- `tunnel_onwards_with_param_default_choice.ink.json`
  - "Story tunnel_onwards_with_param_default_choice" — `src/runtime/story.zig:3831`
- `tunnel_vs_thread_behaviour.ink.json`
  - "Story tunnel_vs_thread_behaviour" — `src/runtime/story.zig:3845`

#### `runtime/evaluation/`

- `arithmetic.ink.json`
  - "Story arithmetic" — `src/runtime/story.zig:2063`
  - "runStory arithmetic" — `src/test/helpers.zig:121`
- `basic_string_literals.ink.json`
  - "Story basic_string_literals" — `src/runtime/story.zig:3867`
- `evaluating_function_variable_state_bug.ink.json`
  - "Story evaluating_function_variable_state_bug" — `src/runtime/story.zig:3881`
- `evaluating_ink_functions_from_game.ink.json`
  - "Story evaluating_ink_functions_from_game" — `src/runtime/story.zig:3896`
- `evaluating_ink_functions_from_game_2.ink.json`
  - "Story evaluating_ink_functions_from_game_2" — `src/runtime/story.zig:3909`
  - "evaluateFunction: func1 returns int value and captures text" — `src/runtime/story.zig:3561`
  - "evaluateFunction: func2 returns null (void function)" — `src/runtime/story.zig:3579`
  - "evaluateFunction: add(x,y) returns x+y" — `src/runtime/story.zig:3591`
  - "evaluateFunction: story state fully restored after call" — `src/runtime/story.zig:3604`
- `evaluation_stack_leaks.ink.json`
  - "Story evaluation_stack_leaks" — `src/runtime/story.zig:3922`
- `factorial_by_reference.ink.json`
  - "Story factorial_by_reference" — `src/runtime/story.zig:3936`
- `factorial_recursive.ink.json`
  - "Story factorial recursive" — `src/runtime/story.zig:2102`
  - "runStory factorial_recursive" — `src/test/helpers.zig:130`
- `increment.ink.json`
  - "Story increment" — `src/runtime/story.zig:3949`
- `literal_unary.ink.json`
  - "Story literal_unary" — `src/runtime/story.zig:3962`

#### `runtime/extra/`

- `arithmetic_2.ink.json`
  - "Story arithmetic_2" — `src/runtime/story.zig:3977`
- `list_comparison.ink.json`
  - "Story list_comparison" — `src/runtime/story.zig:3991`

#### `runtime/glue/`

- `implicit_inline_glue.ink.json`
  - "Story implicit_inline_glue" — `src/runtime/story.zig:2247`
- `implicit_inline_glue_b.ink.json`
  - "Story implicit_inline_glue_b" — `src/runtime/story.zig:4007`
- `implicit_inline_glue_c.ink.json`
  - "Story implicit_inline_glue_c" — `src/runtime/story.zig:4021`
- `left_right_glue_matching.ink.json`
  - "Story left_right_glue_matching" — `src/runtime/story.zig:4036`
- `simple_glue.ink.json`
  - "Story simple_glue" — `src/runtime/story.zig:2234`

#### `runtime/knots/`

- `knot_do_not_gather.ink.json`
  - "Story knot_do_not_gather" — `src/runtime/story.zig:4053`
- `knot_stitch_gather_counts.ink.json`
  - "knot_stitch_gather_counts: visit counts tracked per knot and stitch" — `src/runtime/story.zig:3189`
  - "visitCountAtPathString: 0 before visit, 1 after" — `src/runtime/story.zig:3629`
- `knot_thread_interaction.ink.json`
  - "Story knot_thread_interaction" — `src/runtime/story.zig:4066`
- `knot_thread_interaction_2.ink.json`
  - "Story knot_thread_interaction_2" — `src/runtime/story.zig:4079`

#### `runtime/lists/`

- `contains_empty_list_always_false.ink.json`
  - "Story contains_empty_list_always_false" — `src/runtime/story.zig:4093`
- `empty_list_origin.ink.json`
  - "Story empty_list_origin" — `src/runtime/story.zig:4106`
- `empty_list_origin_after_assignment.ink.json`
  - "Story empty_list_origin_after_assignment" — `src/runtime/story.zig:4119`
- `list_basic_operations.ink.json`
  - "list_basic_operations: union, intersect, has, hasnt" — `src/runtime/story.zig:3231`
  - "Story list_basic_operations" — `src/runtime/story.zig:4132`
  - "runStory list_basic_operations" — `src/test/helpers.zig:149`
- `list_mixed_items.ink.json`
  - "list_mixed_items: multi-origin list union" — `src/runtime/story.zig:3242`
  - "Story list_mixed_items" — `src/runtime/story.zig:4145`
- `list_random.ink.json`
- `list_range.ink.json`
  - "list_range: range control command and LIST_ALL with origins" — `src/runtime/story.zig:3272`
  - "Story list_range" — `src/runtime/story.zig:4158`
- `list_save_load.ink.json`
  - "save/load round-trip: list variables preserved across list_save_load" — `src/runtime/story.zig:3449`
  - "Story list_save_load" — `src/runtime/story.zig:4171`
- `more_list_operations.ink.json`
  - "more_list_operations: LIST_VALUE, listInt, LIST_ALL, LIST_INVERT" — `src/runtime/story.zig:3253`
  - "Story more_list_operations" — `src/runtime/story.zig:4184`

#### `runtime/logic/`

- `logic_lines_with_newlines.ink.json`
  - "Story logic_lines_with_newlines" — `src/runtime/story.zig:4199`
  - "runStory logic_lines_with_newlines" — `src/test/helpers.zig:89`
- `multiline_logic_with_glue.ink.json`
  - "Story multiline_logic_with_glue" — `src/runtime/story.zig:4212`
- `nested_pass_by_reference.ink.json`
  - "Story nested_pass_by_reference" — `src/runtime/story.zig:4226`
- `print_num.ink.json`
  - "Story print_num" — `src/runtime/story.zig:4239`

#### `runtime/misc/`

- `empty.ink.json`
  - "Story empty" — `src/runtime/story.zig:2050`
- `end.ink.json`
  - "Story end" — `src/runtime/story.zig:4267`
- `end2.ink.json`
  - "Story end2" — `src/runtime/story.zig:4281`
- `end_of_content.ink.json`
  - "Story end_of_content" — `src/runtime/story.zig:4255`
- `escape_character.ink.json`
  - "Story escape_character" — `src/runtime/story.zig:4295`
- `hello_world.ink.json`
  - "Story hello_world" — `src/runtime/story.zig:2035`
  - "Temp var found in function frame" — `src/runtime/story.zig:2263`
  - "Temp var shadows global; global restored after pop" — `src/runtime/story.zig:2285`
  - "currentFlowIsDefaultFlow: true initially, false after switchFlow" — `src/runtime/story.zig:3648`
  - "observeVariable: does not fire for unobserved variable" — `src/runtime/story.zig:3508`
  - "observeVariable: fires when observed global changes" — `src/runtime/story.zig:3478`
  - "resolvePath non-existent returns null" — `src/runtime/story.zig:2379`
  - "resolvePath relative with ^ traverses parent" — `src/runtime/story.zig:2364`
  - "save/load round-trip: hello_world pointer preserved" — `src/runtime/story.zig:3425`
  - "srnd sets story_seed" — `src/runtime/story.zig:2707`
  - "str/str collects strings onto eval stack" — `src/runtime/story.zig:2429`
  - "toJson: fresh state contains required top-level keys" — `src/runtime/story.zig:3407`
  - "turns_since returns -1 for never-visited path" — `src/runtime/story.zig:2689`
  - "loadFixture returns non-empty slice" — `src/test/helpers.zig:54`
  - "runStory hello_world" — `src/test/helpers.zig:60`
- `identifiers_can_start_with_number.ink.json`
  - "Story identifiers_can_start_with_number" — `src/runtime/story.zig:4308`
- `include.ink.json`
  - "Story include" — `src/runtime/story.zig:4321`
- `includes/included_file.ink.json`
- `includes/included_file_2.ink.json`
- `includes/included_file_4.ink.json`
- `nested_include.ink.json`
  - "Story nested_include" — `src/runtime/story.zig:4334`
- `quote_character_significance.ink.json`
  - "Story quote_character_significance" — `src/runtime/story.zig:4347`
- `whitespace.ink.json`
  - "Story whitespace" — `src/runtime/story.zig:4360`

#### `runtime/multiflow/`

- `multi_flow_basics.ink.json`
  - "multi_flow_basics: separate flow states maintained" — `src/runtime/story.zig:3331`
- `multi_flow_save_load_threads.ink.json`
  - "Story multi_flow_save_load_threads" — `src/runtime/story.zig:4510`

#### `runtime/newlines/`

- `newline_at_start_of_multiline_conditional.ink.json`
  - "Story newline_at_start_of_multiline_conditional" — `src/runtime/story.zig:4376`
- `newline_consistency_1.ink.json`
  - "Story newline_consistency_1" — `src/runtime/story.zig:4388`
- `newline_consistency_2.ink.json`
  - "Story newline_consistency_2" — `src/runtime/story.zig:4399`
- `newline_consistency_3.ink.json`
  - "Story newline_consistency_3" — `src/runtime/story.zig:4410`
- `newlines_trimming_with_func_external_fallback.ink.json`
  - "Story newlines_trimming_with_func_external_fallback" — `src/runtime/story.zig:4421`
- `newlines_with_string_eval.ink.json`
  - "Story newlines_with_string_eval" — `src/runtime/story.zig:4433`

#### `runtime/sequences/`

- `all_sequence_types.ink.json`
  - "Stopping sequence clamps at last item" — `src/runtime/story.zig:2719`
  - "Cycle sequence wraps correctly" — `src/runtime/story.zig:2731`
  - "Story all_sequence_types" — `src/runtime/story.zig:4449`
- `blanks_in_inline_sequences.ink.json`
  - "Story blanks_in_inline_sequences" — `src/runtime/story.zig:4461`
- `empty_sequence_content.ink.json`
  - "Story empty_sequence_content" — `src/runtime/story.zig:4474`
- `gather_read_count_with_initial_sequence.ink.json`
  - "Story gather_read_count_with_initial_sequence" — `src/runtime/story.zig:4486`
- `leading_newline_multiline_sequence.ink.json`
  - "Story leading_newline_multiline_sequence" — `src/runtime/story.zig:4497`
- `shuffle_stack_muddying.ink.json`

#### `runtime/strings/`

- `string_constants.ink.json`
  - "Story string_constants" — `src/runtime/story.zig:2450`
- `string_contains.ink.json`
- `string_type_coercion.ink.json`
  - "Story string_type_coercion" — `src/runtime/story.zig:2415`
- `strings_in_choices.ink.json`

#### `runtime/tags/`

- `tags.ink.json`
  - "tags: start_tag/end_tag collects tag strings; content still output" — `src/runtime/story.zig:3173`
  - "choosePathString: jumps to named knot" — `src/runtime/story.zig:3204`
  - "globalTags: returns story-level tags from tags.ink.json" — `src/runtime/story.zig:3667`
- `tags_dynamic_content.ink.json`
  - "Story tags_dynamic_content" — `src/runtime/story.zig:4552`
- `tags_in_choice.ink.json`
  - "Story tags_in_choice" — `src/runtime/story.zig:4567`
- `tags_in_seq.ink.json`
  - "Story tags_in_seq" — `src/runtime/story.zig:4584`
- `tags_on_choice.ink.json`
  - "Story tags_on_choice" — `src/runtime/story.zig:4596`

#### `runtime/threads/`

- `multi_thread.ink.json`
  - "multi_thread: choices from both threads merged" — `src/runtime/story.zig:3307`
- `thread_done.ink.json`
  - "thread_done: forked thread ends with done, main continues" — `src/runtime/story.zig:3296`
- `thread_in_logic.ink.json`
  - "Story thread_in_logic" — `src/runtime/story.zig:4617`
- `top_flow_terminator_should_not_kill_thread_choices.ink.json`
  - "Story top_flow_terminator_should_not_kill_thread_choices" — `src/runtime/story.zig:4630`

#### `runtime/variables/`

- `const.ink.json`
  - "Story const variable" — `src/runtime/story.zig:2089`
- `multiple_constant_references.ink.json`
  - "Story multiple_constant_references" — `src/runtime/story.zig:4647`
- `set_non_existant_variable.ink.json`
  - "Story set_non_existant_variable" — `src/runtime/story.zig:4659`
- `temp_global_conflict.ink.json`
  - "Story temp_global_conflict" — `src/runtime/story.zig:4671`
- `temp_not_found.ink.json`
  - "Story temp_not_found" — `src/runtime/story.zig:4683`
- `temp_usage_in_options.ink.json`
  - "Story temp_usage_in_options" — `src/runtime/story.zig:4695`
- `temporaries_at_global_scope.ink.json`
  - "Story temporaries_at_global_scope" — `src/runtime/story.zig:4709`
- `variable_declaration_in_conditional.ink.json`
  - "Story variable_declaration_in_conditional" — `src/runtime/story.zig:4721`
- `variable_divert_target.ink.json`
  - "Story variable_divert_target" — `src/runtime/story.zig:2475`
  - "turn_indices updated when entering flagged container" — `src/runtime/story.zig:2673`
- `variable_get_set_api.ink.json`
  - "Story variable_get_set_api" — `src/runtime/story.zig:4733`
- `variable_pointer_ref_from_knot.ink.json`
  - "Story variable_pointer_ref_from_knot" — `src/runtime/story.zig:4745`
- `variable_swap_recurse.ink.json`
  - "Story variable_swap_recurse" — `src/runtime/story.zig:4757`
- `variable_tunnel.ink.json`
  - "Story variable_tunnel" — `src/runtime/story.zig:4769`
- `warn_variable_not_found_1.ink.json`
  - "Story warn_variable_not_found_1" — `src/runtime/story.zig:4781`
- `warn_variable_not_found_2.ink.json`
  - "Story warn_variable_not_found_2" — `src/runtime/story.zig:4793`

#### `runtime/weaves/`

- `conditional_choice_in_weave.ink.json`
  - "Story conditional_choice_in_weave" — `src/runtime/story.zig:4807`
- `conditional_choice_in_weave_2.ink.json`
  - "Story conditional_choice_in_weave_2" — `src/runtime/story.zig:4825`
- `unbalanced_weave_indentation.ink.json`
  - "Story unbalanced_weave_indentation" — `src/runtime/story.zig:4844`
- `weave_gathers.ink.json`
  - "Story weave_gathers" — `src/runtime/story.zig:4864`
  - "runStory weave_gathers choice path one" — `src/test/helpers.zig:99`
  - "runStory weave_gathers choice path four" — `src/test/helpers.zig:110`
- `weave_options.ink.json`
  - "Story weave_options" — `src/runtime/story.zig:4881`
- `weave_within_sequence.ink.json`
  - "Story weave_within_sequence" — `src/runtime/story.zig:4897`
