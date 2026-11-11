//! Shared core for the data-oriented runtime and compiler (plan §4.1).

pub const fault = @import("fault.zig");
pub const death_cases = @import("death_cases.zig");
pub const index = @import("index.zig");
pub const limits = @import("limits.zig");
pub const string_pool = @import("string_pool.zig");

test {
    _ = fault;
    _ = death_cases;
    _ = index;
    _ = limits;
    _ = string_pool;
}
