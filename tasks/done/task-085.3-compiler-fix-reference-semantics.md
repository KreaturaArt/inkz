# TASK-85.3: Compiler: fix reference semantics

- Status: Done
- Priority: high
- Labels: compiler, integration
- Dependencies: —
- Parent: TASK-85
- Created: 2026-04-07 · Updated: 2026-04-07

## Description

Fix compiler handling for pass-by-reference arguments and variable pointer propagation in function calls. Representative failures were runtime/evaluation/factorial_by_reference.ink, runtime/logic/nested_pass_by_reference.ink, and runtime/variables/variable_pointer_ref_from_knot.ink.

## Acceptance Criteria
- [ ] factorial_by_reference.ink passes compileAndRun
- [ ] nested_pass_by_reference.ink passes compileAndRun
- [ ] variable_pointer_ref_from_knot.ink passes compileAndRun

## Implementation Notes

Added function-signature-aware call lowering so ref parameters compile to variable-pointer objects instead of plain value reads.

Serialized Parsed.Expression.var_pointer through codegen/serializer and verified reference fixtures now pass.

Suite moved from 462 pass / 23 fail to 465 pass / 20 fail after the reference fix.

## Final Summary

Fixed pass-by-reference compilation by lowering ref call arguments to variable-pointer objects using function signature metadata. This cleared the main reference-semantics fixtures and moved the suite to 465/485 passing.
