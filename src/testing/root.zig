//! The test harnesses and gates over the runtime: `zig build test-runtime` includes them.

test {
    _ = @import("transcript.zig");
    _ = @import("harness.zig");
    _ = @import("cases.zig");
    _ = @import("isolated.zig");
    _ = @import("ground_truth_test.zig");
    _ = @import("transcripts.zig");
    _ = @import("oracle.zig");
    _ = @import("known_bugs.zig");
    _ = @import("simulation.zig");
    _ = @import("zero_allocation.zig");
    _ = @import("save_load_test.zig");
    _ = @import("text_cache_test.zig");
    _ = @import("fitted_limits_test.zig");
    _ = @import("program_image_test.zig");
    _ = @import("fuzz_ink.zig");
    _ = @import("bench_io_test.zig");
    _ = @import("bench_profile_test.zig");
}
