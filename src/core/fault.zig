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
