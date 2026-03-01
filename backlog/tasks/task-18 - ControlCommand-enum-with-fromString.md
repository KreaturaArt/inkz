---
id: TASK-18
title: ControlCommand enum with fromString
status: Done
assignee: []
created_date: '2026-02-23 19:42'
updated_date: '2026-03-01 17:43'
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
- [x] #1 All 24 JSON command strings map to correct variants
- [x] #2 fromString returns null for unknown strings
- [x] #3 fromString("srnd") == .seed_random
- [x] #4 fromString("#") == .start_tag
- [x] #5 fromString("listInt") == .list_from_int
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented in src/runtime/value.zig using std.StaticStringMap. Verified by test 2 (runtime.value.test.ControlCommand.fromString). All 24 command strings mapped; fromString returns null for unknown strings.

Gap found on verification: AC #5 (fromString("listInt") == .list_from_int) is not in the test — the test only checks ev, ->->, choiceCnt, srnd, #, done, unknown. AC #1 (all 24 strings) is therefore also not exhaustively verified. Need to add the listInt assertion and verify the full 24-entry map.

Fixed: 'ControlCommand.fromString' test now checks all 24 command strings exhaustively, including listInt → .list_from_int, range, lrnd, thread, end, and all others.
<!-- SECTION:NOTES:END -->
