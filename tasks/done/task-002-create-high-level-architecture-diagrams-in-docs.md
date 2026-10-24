# TASK-2: Create high-level architecture diagrams in docs/

- Status: Done
- Priority: high
- Labels: —
- Dependencies: —
- Created: 2026-02-23 · Updated: 2026-02-23

## Description

Create docs/Architecture.md with ASCII/Mermaid diagrams covering: (1) full compiler+runtime pipeline, (2) runtime data flow (step loop, eval stack, output stream), (3) Container/content object model, (4) callstack / flow model.

## Final Summary

Created docs/Architecture.md with 8 Mermaid diagrams: (1) Full pipeline overview compiler→runtime→game, (2) Runtime object model (Container + RuntimeObject tagged union), (3) Runtime state machine (Story/StoryState/CallStack/Thread/Element), (4) Parser architecture (labeled switch tokenizer → StringParser combinators → InkParser → AST), (5) Code generation two-pass sequence diagram, (6) Step loop & evaluation model flowchart, (7) Stage 2 tokenizer labeled switch detail, (8) Memory strategy / allocator hierarchy.
