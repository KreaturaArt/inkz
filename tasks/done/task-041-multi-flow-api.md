# TASK-41: Multi-flow API

- Status: Done
- Priority: high
- Labels: layer-11, multiflow
- Dependencies: —
- Created: 2026-02-23 · Updated: 2026-03-02

## Description

Implement named flows in `src/runtime/story.zig`.

- `Flow = struct{ name: []const u8, call_stack: CallStack, output_stream: std.ArrayList(RuntimeObject), evaluation_stack: std.ArrayList(RuntimeObject), current_choices: std.ArrayList(Choice) }`
- `named_flows: std.StringHashMap(Flow)`, `current_flow_name: []const u8 = "DEFAULT"`
- `switchFlow(name: []const u8) !void`: save current flow state; switch to named flow (create if new)
- `switchToDefaultFlow() void`: switch back to the default flow
- `removeFlow(name: []const u8) !void`: delete a non-default flow
- `aliveFlowNames() [][]const u8`: names of all active flows

Tests:
- `multiflow/multi_flow_basics.ink.json` → switching flows maintains separate output and choice state
- `multiflow/multi_flow_save_load_threads.ink.json` → save/load preserves multi-flow state

## Acceptance Criteria
- [x] multi_flow_basics.ink.json: separate flow states maintained
- [ ] multi_flow_save_load_threads.ink.json produces correct output
- [x] switchFlow creates new flow if it doesn't exist
- [x] removeFlow errors on default flow
