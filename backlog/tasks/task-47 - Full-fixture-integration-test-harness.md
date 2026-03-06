---
id: TASK-47
title: Full fixture integration test harness
status: Done
assignee: []
created_date: '2026-02-23 19:46'
updated_date: '2026-03-06 14:02'
labels:
  - layer-15
  - integration
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement `runStory` helper and comprehensive fixture integration tests in `src/test/helpers.zig` and a new integration test file.

`runStory(json: []const u8, choices: []const usize, allocator) ![]u8`:
- Create Story from JSON
- Loop: `cont()` → if choices provided, `chooseChoiceIndex(choices[i])` → repeat
- Concatenate all cont() outputs and return

Write integration tests for all fixtures that can be driven without choices (choice-free) or with a known choice sequence. For fixtures with `// RESULT: "..."` in their source `.ink` file, use that as the expected output.

Tests:
- `weaves/weave_gathers.ink.json` → correct weave output
- `conditions/conditionals.ink.json` → correct conditional branching output
- `conditions/else_branches.ink.json` → correct else/else-if output
- `logic/logic_lines_with_newlines.ink.json` → correct logic output
- All choice-free fixtures must pass (run all, report any failures clearly)
- The test file must report which fixture failed and what the actual vs expected output was
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 runStory helper drives story through choice sequence correctly
- [ ] #2 All choice-free fixtures pass
- [ ] #3 weave_gathers.ink.json produces correct output
- [ ] #4 conditionals.ink.json and else_branches.ink.json produce correct output
- [ ] #5 Failing tests report fixture name + actual vs expected output
<!-- AC:END -->
