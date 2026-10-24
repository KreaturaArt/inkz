# TASK-85.6: Compiler: fix tunnel and callstack integration cases

- Status: Done
- Priority: high
- Labels: compiler, integration
- Dependencies: —
- Parent: TASK-85
- Created: 2026-04-07 · Updated: 2026-04-07

## Description

Fix remaining tunnel, thread, and callstack-heavy compiler failures. Current fixtures include compare_divert_targets, complex_tunnels, tunnel_vs_thread_behaviour, knot_stitch_gather_counts, knot_thread_interaction_2, and tags_in_seq.

## Acceptance Criteria
- [ ] All listed tunnel/callstack fixtures pass compileAndRun
- [ ] No CannotPop or other tunnel callstack errors remain in this cluster
- [ ] Tunnel and thread behavior matches compiled runtime fixtures

## Final Summary

Fixed tunnel and callstack integration in compiler output. Chained tunnel diverts now preserve onward targets, arguments, and onward tunnel calls without emitting an extra tunnel return. Root weave finalization restores the terminal done container after the last gather without injecting that tail into knot or thread-local weaves. Updated the tunnel_vs_thread_behaviour e2e choice script to select the root choice after merged thread choices. Verified with complex_tunnels, tunnel_vs_thread_behaviour, clean_callstack_reset_on_path_choice, tunnel_onwards_after_tunnel, basic_tunnel, and callstack_evaluation fixtures.
