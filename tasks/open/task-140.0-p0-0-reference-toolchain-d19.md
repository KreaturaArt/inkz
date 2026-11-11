# TASK-140.0: P0.0 Reference toolchain (D19)

- Status: To Do
- Priority: high
- Labels: dod, tooling, testing
- Dependencies: —
- Parent: TASK-140
- Created: 2026-10-24 · Updated: 2026-11-11

## Description

Plan item P0.0 in `docs/DODMigrationPlan.md` §6 (Phase 0).

- `mise.toml` pins `dotnet` 8 and a release of inklecate.
- `reference/ink_harness/` holds a C# console project referencing a pinned ink commit (`ink-engine-runtime`). It reads a case (`.ink`, or `.ink.json`, plus an action script, see P0.10) and writes `.expected`, RNG sequences and save JSON.
- mise tasks: `reference:setup`, `reference:expected` (regenerate all, or one case), `reference:random` (sequences for P1.8), `reference:saves` (§4.10 interop saves).
- Every output file starts with a provenance header.

Follow `TIGER_STYLE.md` and plan §3: no recursion, explicit limits, ≥ 2 assertions per function, ≤ 70-line functions, snake_case.

## Acceptance Criteria
- [ ] `mise run reference:expected -- <case>` regenerates a checked-in case byte for byte.
- [ ] A Zig test asserts that every ground-truth file has a valid provenance header.
- [ ] The Zig suite passes on a machine without .NET.
- [ ] Validated by unit tests.

## Implementation Notes

Back-of-envelope sketch (plan §3.2, required before writing code): bytes and cache lines touched per operation.

## Final Summary
