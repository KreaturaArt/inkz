//! Shared core for the data-oriented runtime and compiler (plan §4.1).

pub const fault = @import("fault.zig");
pub const index = @import("index.zig");
pub const limits = @import("limits.zig");
pub const string_pool = @import("string_pool.zig");
pub const extra = @import("extra.zig");
pub const bounded_stack = @import("bounded_stack.zig");
pub const work_stack = @import("work_stack.zig");
pub const tag_set = @import("tag_set.zig");
pub const dotnet_random = @import("dotnet_random.zig");
pub const path = @import("path.zig");
pub const counting_allocator = @import("counting_allocator.zig");
pub const instruction = @import("instruction.zig");
pub const container = @import("container.zig");
pub const program = @import("program.zig");
pub const program_builder = @import("program_builder.zig");
pub const program_dump = @import("program_dump.zig");
pub const ink_json = @import("ink_json.zig");
pub const program_image = @import("program_image.zig");

test {
    _ = fault;
    _ = index;
    _ = limits;
    _ = string_pool;
    _ = extra;
    _ = bounded_stack;
    _ = work_stack;
    _ = tag_set;
    _ = dotnet_random;
    _ = path;
    _ = counting_allocator;
    _ = instruction;
    _ = container;
    _ = program;
    _ = program_builder;
    _ = program_dump;
    _ = ink_json;
    _ = program_image;
    _ = @import("sizes_test.zig");
}
