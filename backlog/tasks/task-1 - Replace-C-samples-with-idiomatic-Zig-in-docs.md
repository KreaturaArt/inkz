---
id: TASK-1
title: Replace C# samples with idiomatic Zig in docs/
status: Done
assignee: []
created_date: '2026-02-23 18:13'
updated_date: '2026-02-23 18:25'
labels: []
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Replace all C# code samples in RunningYourInk.md and ArchitectureAndDevOverview.md with idiomatic Zig 0.14 equivalents that reflect the Zig runtime API being built. Preserve all explanatory prose; only swap code blocks.
<!-- SECTION:DESCRIPTION:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Replaced all C# code samples in ArchitectureAndDevOverview.md and RunningYourInk.md with idiomatic Zig 0.14 equivalents. Key changes: parser rules use save()/restore() with orelse, combinators use comptime generics and function pointers, Story API uses error unions with try, Unity/MonoBehaviour wrappers replaced with Zig structs, delegates replaced with anonymous struct function pointers, List&lt;T&gt; replaced with slices/ArrayList, camelCase method names updated to snake_case fields.
<!-- SECTION:FINAL_SUMMARY:END -->
