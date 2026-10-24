# TASK-85.4: Compiler: fix default-choice and choice-state generation

- Status: Done
- Priority: high
- Labels: compiler, integration
- Dependencies: —
- Parent: TASK-85
- Created: 2026-04-07 · Updated: 2026-04-07

## Description

Fix compiler generation for default choices, rollback behavior, and choice container paths. Current failing fixtures include various_default_choices, state_rollback_over_default_choice, temp_usage_in_options, and tunnel_onwards_with_param_default_choice.

## Acceptance Criteria
- [x] All listed choice/default-choice fixtures pass compileAndRun
- [x] Choice path generation matches runtime semantics
- [x] State rollback behavior matches compiled fixture output

## Final Summary

Fixed compiler handling for invisible default choices and choice labels within weaves. Fallback choices now preserve their inline/body content without emitting synthetic empty diverts, choice numbering stays stable across gathers so label-based diverts resolve to the right containers, and choice-line parsing now supports inline labels plus tunnel-onwards diverts. Verified with targeted Zig tests for default choice fixtures, rollback behavior, temp-usage-in-options, and tunnel-onwards default-choice cases.
