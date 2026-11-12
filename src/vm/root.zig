//! The new runtime (plan §4.5–4.8, D21): values, state and the VM. It lives in src/vm/ until
//! the old runtime in src/runtime/ is deleted (P9.1).

pub const value = @import("value.zig");
pub const native = @import("native.zig");
pub const lists = @import("lists.zig");
pub const heap = @import("heap.zig");
pub const call_stack = @import("call_stack.zig");
pub const output = @import("output.zig");
pub const choices = @import("choices.zig");
pub const state = @import("state.zig");
pub const flows = @import("flows.zig");
pub const lookahead = @import("lookahead.zig");

test {
    _ = value;
    _ = native;
    _ = lists;
    _ = heap;
    _ = call_stack;
    _ = output;
    _ = choices;
    _ = state;
    _ = flows;
    _ = lookahead;
}
