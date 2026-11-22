//! Test root for the tools: `zig build test-tools`.

test {
    _ = @import("lint.zig");
    _ = @import("snapshot.zig");
    _ = @import("doctest.zig");
    _ = @import("ci_test.zig");
    _ = @import("code_size.zig");
}
