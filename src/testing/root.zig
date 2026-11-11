//! The engine-neutral test layer (plan P0.11): `zig build test-runtime` includes it.

pub const transcript = @import("transcript.zig");
pub const old_engine = @import("old_engine.zig");
pub const ground_truth = @import("ground_truth_test.zig");
pub const cases = @import("cases.zig");
pub const transcripts = @import("transcripts.zig");

test {
    _ = transcript;
    _ = old_engine;
    _ = ground_truth;
    _ = transcripts;
}
