//! `zig build bench-profile`: src/bench.zig (`bench profile`) with the profile zones of
//! src/core/profile.zig compiled in, which only a root file can do.

/// Compiles the profile zones in (src/core/profile.zig).
pub const inkz_profile = true;

pub const main = @import("bench.zig").main;
