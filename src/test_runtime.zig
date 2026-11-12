//! Test root for the runtime and the engine-neutral test layer: `zig build test-runtime`.

test {
    _ = @import("runtime/root.zig");
    _ = @import("death_cases.zig");
    _ = @import("testing/root.zig");
}
