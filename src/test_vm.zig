//! Test root for the new runtime: `zig build test-vm`.

test {
    _ = @import("vm/root.zig");
}
