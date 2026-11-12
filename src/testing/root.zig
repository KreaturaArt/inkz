//! The engine-neutral test layer (plan P0.11): `zig build test-runtime` includes it.

pub const transcript = @import("transcript.zig");
pub const ground_truth = @import("ground_truth_test.zig");
pub const cases = @import("cases.zig");
pub const oracle = @import("oracle.zig");
pub const known_bugs = @import("known_bugs.zig");
pub const simulation = @import("simulation.zig");
pub const transcripts = @import("transcripts.zig");
pub const weave_reproductions = @import("weave_reproductions.zig");
pub const new_engine_cases = @import("new_engine_cases.zig");
pub const zero_allocation = @import("zero_allocation.zig");
pub const save_load_test = @import("save_load_test.zig");
pub const text_cache_test = @import("text_cache_test.zig");
pub const fitted_limits_test = @import("fitted_limits_test.zig");

test {
    _ = transcript;
    _ = ground_truth;
    _ = transcripts;
    _ = oracle;
    _ = known_bugs;
    _ = simulation;
    _ = weave_reproductions;
    _ = new_engine_cases;
    _ = zero_allocation;
    _ = save_load_test;
    _ = text_cache_test;
    _ = fitted_limits_test;
}
