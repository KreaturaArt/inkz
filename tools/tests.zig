//! Test root for the tools: `zig build test-tools`.

test {
    _ = @import("lint.zig");
    _ = @import("ground_truth.zig");
    _ = @import("snapshot.zig");
}
