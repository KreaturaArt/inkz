//! Shared core for the data-oriented runtime and compiler (plan §4.1).

pub const fault = @import("fault.zig");
pub const death_cases = @import("death_cases.zig");
pub const index = @import("index.zig");
pub const limits = @import("limits.zig");
pub const string_pool = @import("string_pool.zig");
pub const extra = @import("extra.zig");

test {
    _ = fault;
    _ = death_cases;
    _ = index;
    _ = limits;
    _ = string_pool;
    _ = extra;
}
