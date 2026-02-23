---
id: TASK-18
title: ControlCommand enum with fromString
status: To Do
assignee: []
created_date: '2026-02-23 19:42'
labels:
  - layer-1
  - core-types
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement `ControlCommand` enum in `src/runtime/value.zig` with `fromString([]const u8) ?ControlCommand`. All 24 JSON command strings:

| String | Variant |
|--------|---------|
| `"ev"` | `.eval_start` |
| `"/ev"` | `.eval_end` |
| `"out"` | `.output` |
| `"pop"` | `.pop_eval_stack` |
| `"du"` | `.duplicate` |
| `"~ret"` | `.pop_function` |
| `"->->"` | `.pop_tunnel` |
| `"str"` | `.begin_string` |
| `"/str"` | `.end_string` |
| `"nop"` | `.no_op` |
| `"choiceCnt"` | `.choice_count` |
| `"turns"` | `.turns_since` |
| `"turn"` | `.turn_index` |
| `"visit"` | `.visit_index` |
| `"seq"` | `.sequence_shuffle_index` |
| `"srnd"` | `.seed_random` |
| `"#"` | `.start_tag` |
| `"/#"` | `.end_tag` |
| `"listInt"` | `.list_from_int` |
| `"range"` | `.list_range` |
| `"lrnd"` | `.list_random` |
| `"thread"` | `.begin_thread` |
| `"done"` | `.done` |
| `"end"` | `.end_of_story` |

Tests:
- `ControlCommand.fromString("ev") == .eval_start`
- `ControlCommand.fromString("->->") == .pop_tunnel`
- `ControlCommand.fromString("choiceCnt") == .choice_count`
- `ControlCommand.fromString("srnd") == .seed_random`
- `ControlCommand.fromString("#") == .start_tag`
- `ControlCommand.fromString("done") == .done`
- `ControlCommand.fromString("unknown") == null`
- All 24 strings map to a non-null variant (exhaustive test)
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 All 24 JSON command strings map to correct variants
- [ ] #2 fromString returns null for unknown strings
- [ ] #3 fromString("srnd") == .seed_random
- [ ] #4 fromString("#") == .start_tag
- [ ] #5 fromString("listInt") == .list_from_int
<!-- AC:END -->
