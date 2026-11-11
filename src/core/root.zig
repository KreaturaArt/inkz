//! Shared core for the data-oriented runtime and compiler (plan §4.1).

pub const fault = @import("fault.zig");
pub const death_cases = @import("death_cases.zig");
pub const index = @import("index.zig");
pub const limits = @import("limits.zig");
pub const string_pool = @import("string_pool.zig");
pub const extra = @import("extra.zig");
pub const bounded_stack = @import("bounded_stack.zig");
pub const work_stack = @import("work_stack.zig");
pub const tag_set = @import("tag_set.zig");
pub const dotnet_random = @import("dotnet_random.zig");
pub const path = @import("path.zig");

test {
    _ = fault;
    _ = death_cases;
    _ = index;
    _ = limits;
    _ = string_pool;
    _ = extra;
    _ = bounded_stack;
    _ = work_stack;
    _ = tag_set;
    _ = dotnet_random;
    _ = path;
    _ = @import("sizes_test.zig");
}
