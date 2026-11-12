//! The new runtime (plan §4.5–4.8, D21): values, state and the VM. It lives in src/vm/ until
//! the old runtime in src/runtime/ is deleted (P9.1).

pub const value = @import("value.zig");

test {
    _ = value;
}
