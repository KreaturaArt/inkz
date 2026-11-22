//! `has_no_pointers`: whether a type holds no pointer, slice or function pointer anywhere
//! in it. Data that is copied, saved or snapshotted by value (flow buffers, the
//! lookahead's undo log, values) must not point into memory: a copy would alias it, and a
//! moved heap or a loaded save would leave it dangling (docs/Guidelines.md).

const std = @import("std");
const assert = std.debug.assert;

/// Walks `T`'s fields, payloads, children and elements with an explicit stack (no
/// recursion): false at the first pointer.
pub fn has_no_pointers(comptime T: type) bool {
    comptime {
        @setEvalBranchQuota(100_000);
        var pending: [256]type = undefined;
        pending[0] = T;
        var count: usize = 1;
        while (count > 0) {
            count -= 1;
            const U = pending[count];
            switch (@typeInfo(U)) {
                .pointer, .@"fn", .@"opaque", .@"anyframe", .frame => return false,
                .@"struct" => |info| for (info.field_types) |Field| {
                    pending[count] = Field;
                    count += 1;
                },
                .@"union" => |info| for (info.field_types) |Field| {
                    pending[count] = Field;
                    count += 1;
                },
                .optional => |info| {
                    pending[count] = info.child;
                    count += 1;
                },
                .array => |info| {
                    pending[count] = info.child;
                    count += 1;
                },
                .vector => |info| {
                    pending[count] = info.child;
                    count += 1;
                },
                .error_union => |info| {
                    pending[count] = info.payload;
                    count += 1;
                },
                else => {},
            }
            assert(count < pending.len);
        }
        return true;
    }
}

test "has_no_pointers rejects pointers anywhere and accepts plain data" {
    const index = @import("index.zig");
    const Slice = struct { bytes: []const u8 };
    const Pointer = struct { at: *u32 };
    const OptionalPointer = struct { at: ?*const u32 };
    const Nested = struct { inner: struct { deep: [2]struct { leaf: ?[]u8 } } };
    const Function = struct { callback: *const fn () void };
    const InUnion = union(enum) { plain: u32, pointer: *u8 };
    comptime assert(!has_no_pointers(Slice));
    comptime assert(!has_no_pointers(Pointer));
    comptime assert(!has_no_pointers(OptionalPointer));
    comptime assert(!has_no_pointers(Nested));
    comptime assert(!has_no_pointers(Function));
    comptime assert(!has_no_pointers(InUnion));
    const Packed = packed struct(u32) { kind: u2, index: u30 };
    const Plain = struct { id: index.StringId, slot: index.GlobalSlot, flags: Packed, at: [3]u32 };
    const Tagged = union(enum) { integer: i32, float: f32, none };
    comptime assert(has_no_pointers(index.ContainerIndex));
    comptime assert(has_no_pointers(Packed));
    comptime assert(has_no_pointers(Plain));
    comptime assert(has_no_pointers(Tagged));
    comptime assert(has_no_pointers(?u32));
    try std.testing.expect(comptime has_no_pointers(Plain));
}
