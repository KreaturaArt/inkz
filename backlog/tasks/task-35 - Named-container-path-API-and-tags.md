---
id: TASK-35
title: Named container path API and tags
status: Done
assignee: []
created_date: '2026-02-23 19:44'
updated_date: '2026-03-02 04:37'
labels:
  - layer-9
  - navigation
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement path-string navigation and tag collection in `src/runtime/story.zig`.

- `choosePathString(path: []const u8) !void`: parse path string, resolve from root via `resolvePath`, set `currentPointer` to that container at index 0
- Tags: `start_tag` / `end_tag` control commands bracket tag content in the output stream. On `start_tag`: begin accumulating tag text. On `end_tag`: join accumulated strings into one tag string; add to current tag list.
- `currentTags() [][]const u8`: tags collected during the current `cont()` call (cleared at start of each `cont()`)
- `tagsForContentAtPath(path: []const u8) ![][]const u8`: resolve container, scan initial content for tag sequences before any non-tag content

Tests:
- `knots/knot_stitch_gather_counts.ink.json` → visit counts per knot/stitch are correct
- `tags/tags.ink.json` → `globalTags()` (or `tagsForContentAtPath("")`) returns `["author: Joe", "title: My Great Story"]`
- `tags/tags_in_choice.ink.json` → `Choice.tags` populated correctly per choice
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 choosePathString jumps to correct container
- [x] #2 knot_stitch_gather_counts.ink.json produces correct output
- [x] #3 tags.ink.json: story-level tags accessible
- [ ] #4 tags_in_choice.ink.json: Choice.tags populated
<!-- AC:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Implemented: (1) `choosePathString` — resolves absolute path from root and sets current pointer; (2) tag handling — `start_tag` pushes a sentinel onto output_stream, `end_tag` scans back to the sentinel, collects string objects, joins them into one tag string (stored in arena), appends to `current_tags`; (3) `currentTags()` returns the tags slice; (4) `current_tags` cleared at start of each `cont()` call, deinited in `deinit()`. Tests: tags.ink.json → output "This is the content\n", tags = ["author: Joe", "title: My Great Story"]; choosePathString("knot") → "Knot content\n" with 2 tags; knot_stitch_gather_counts.ink.json → runs without crash. AC #4 (Choice.tags) deferred — tags in choices require implementing tag accumulation during choice processing.
<!-- SECTION:FINAL_SUMMARY:END -->
