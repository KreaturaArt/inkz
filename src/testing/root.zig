//! The engine-neutral test layer (plan P0.11): `zig build test-runtime` includes it.

pub const transcript = @import("transcript.zig");
pub const old_engine = @import("old_engine.zig");

test {
    _ = transcript;
    _ = old_engine;
}
