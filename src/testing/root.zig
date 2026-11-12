//! The engine-neutral test layer (plan P0.11): `zig build test-runtime` includes it.

pub const transcript = @import("transcript.zig");
pub const old_engine = @import("old_engine.zig");
pub const ground_truth = @import("ground_truth_test.zig");
pub const cases = @import("cases.zig");
pub const oracle = @import("oracle.zig");
pub const known_bugs = @import("known_bugs.zig");
pub const simulation = @import("simulation.zig");
pub const loader_comparison = @import("loader_comparison.zig");
pub const transcripts = @import("transcripts.zig");
pub const weave_reproductions = @import("weave_reproductions.zig");
pub const new_engine_cases = @import("new_engine_cases.zig");
pub const zero_allocation = @import("zero_allocation.zig");

test {
    _ = transcript;
    _ = old_engine;
    _ = ground_truth;
    _ = transcripts;
    _ = oracle;
    _ = known_bugs;
    _ = simulation;
    _ = loader_comparison;
    _ = weave_reproductions;
    _ = new_engine_cases;
    _ = zero_allocation;
}
