//! `std.testing.checkAllAllocationFailures` over an allocator that never resizes in place.
//! Zig 0.17.0's check let in-place resizes succeed, and whether one does depends on where
//! the testing allocator placed a block, so the number of allocations to fail changed from
//! run to run (`error.NondeterministicMemoryUsage`); 0.17.1 fails every resize itself. With
//! resizes refused here, both versions see the same allocations every run.

// lint: allow assertion_density: a test helper forwarding to the testing allocator.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn check(test_fn: anytype, extra_args: anytype) !void {
    var no_resize: NoResize = .{ .child = std.testing.allocator };
    try std.testing.checkAllAllocationFailures(no_resize.allocator(), test_fn, extra_args);
}

const NoResize = struct {
    child: Allocator,

    fn allocator(self: *NoResize) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = Allocator.noResize,
            .remap = Allocator.noRemap,
            .free = free,
        } };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *NoResize = @ptrCast(@alignCast(context));
        return self.child.rawAlloc(len, alignment, ret);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *NoResize = @ptrCast(@alignCast(context));
        self.child.rawFree(memory, alignment, ret);
    }
};
