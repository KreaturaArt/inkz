//! The `check()` / `verify()` convention for invariants.
//!
//! Every structure with invariants has two methods:
//! - `check(self) Fault` returns the first broken invariant as a named value, or `.ok`. It
//!   never panics, so tests can corrupt a structure on purpose and inspect the result.
//! - `verify(self) void` calls `fault.verify(self.check())`, which panics on anything but
//!   `.ok`. Production code calls `verify` at its boundaries (pair assertions).
//!
//! `Fault` is a per-structure `enum` that has an `ok` member.

const std = @import("std");
const assert = std.debug.assert;

/// Panics with the fault's name unless it is `.ok`. Always on, also in ReleaseFast, because a
/// broken invariant must never continue silently.
pub fn verify(fault: anytype) void {
    const Fault = @TypeOf(fault);
    comptime assert(@typeInfo(Fault) == .@"enum");
    comptime assert(@hasField(Fault, "ok"));
    if (fault != .ok) std.debug.panic("verify failed: {t}", .{fault});
}

/// The convention on a small structure: a window into a fixed buffer.
const Window = struct {
    first: u32,
    count: u32,
    capacity: u32,

    const Fault = enum { ok, capacity_zero, first_out_of_bounds, end_out_of_bounds };

    fn check(window: Window) Fault {
        if (window.capacity == 0) return .capacity_zero;
        if (window.first >= window.capacity) return .first_out_of_bounds;
        if (window.count > window.capacity - window.first) return .end_out_of_bounds;
        assert(window.first + window.count <= window.capacity);
        assert(window.capacity > 0);
        return .ok;
    }
};

test "check reports each broken invariant by name" {
    // check() makes corruption visible without panicking: one valid
    // window, then one corruption per invariant.
    const valid: Window = .{ .first = 2, .count = 3, .capacity = 8 };
    try std.testing.expectEqual(Window.Fault.ok, valid.check());
    verify(valid.check());

    var corrupt = valid;
    corrupt.capacity = 0;
    try std.testing.expectEqual(Window.Fault.capacity_zero, corrupt.check());
    corrupt = valid;
    corrupt.first = 8;
    try std.testing.expectEqual(Window.Fault.first_out_of_bounds, corrupt.check());
    corrupt = valid;
    corrupt.count = 7;
    try std.testing.expectEqual(Window.Fault.end_out_of_bounds, corrupt.check());
}
