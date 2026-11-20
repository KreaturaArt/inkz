//! Size guards for core types. Every hot-path type registers its size here,
//! so a field added in passing can't silently grow memory use or `Limits.bytes_total`.
//!
//! Types stored as SoA (`std.MultiArrayList`) are measured with `soa_bytes`: the sum of the
//! field sizes, which is what each element costs across all arrays. Types added in later
//! phases (`Value`, `Instruction`, `Frame`, `OutputItem`, `Node`, `Token`) register here when
//! they are created, against `limits.element_bytes` where the budget counts them.

const std = @import("std");
const assert = std.debug.assert;
const index = @import("index.zig");
const limits = @import("limits.zig");
const bounded_stack = @import("bounded_stack.zig");
const instruction = @import("instruction.zig");

/// Bytes per element when `T` is stored as a `std.MultiArrayList` (one array per field).
pub fn soa_bytes(comptime T: type) comptime_int {
    const info = @typeInfo(T).@"struct";
    comptime assert(info.layout == .auto);
    comptime assert(info.field_types.len > 0);
    var total: comptime_int = 0;
    for (info.field_types) |Field| total += @sizeOf(Field);
    return total;
}

test "soa_bytes adds field sizes without padding" {
    // The helper measures SoA cost, not struct size: a u8 + u32 struct is 8 B as
    // a struct but 5 B per element in SoA.
    const Sample = struct { tag: u8, payload: u32 };
    try std.testing.expectEqual(8, @sizeOf(Sample));
    try std.testing.expectEqual(5, soa_bytes(Sample));
}

test "index newtypes are one word" {
    // Typed indices cost nothing over u32: check each one.
    const types = [_]type{
        index.ContainerIndex, index.InstructionIndex, index.StringId,      index.NodeIndex,
        index.TokenIndex,     index.GlobalSlot,       index.ListItemIndex, index.ListOriginIndex,
        index.ExternalIndex,  index.FlowIndex,        index.FileIndex,
    };
    inline for (types) |T| try std.testing.expectEqual(4, @sizeOf(T));
}

test "limits and stack headers stay small" {
    // Control structures don't bloat the per-story footprint: limits are all u32
    // fields; a stack header is a slice plus a count.
    const field_count = @typeInfo(limits.Limits).@"struct".field_names.len;
    try std.testing.expectEqual(field_count * 4, @sizeOf(limits.Limits));
    try std.testing.expect(@sizeOf(bounded_stack.BoundedStack(u32)) <= 24);
}

test "planned element sizes leave room for their contents" {
    // The budget's planned sizes are consistent with each other before the types exist.
    // A temp is a name plus a value; a global is a value plus its default.
    const bytes = limits.element_bytes;
    try std.testing.expectEqual(@sizeOf(index.StringId) + bytes.value, bytes.temp);
    try std.testing.expectEqual(2 * bytes.value, bytes.global);
    try std.testing.expectEqual(@sizeOf(index.ContainerIndex), bytes.ancestor);
}

test "an instruction is 5 bytes in SoA" {
    // Soa_bytes of Instruction, and the opcode alone is one byte.
    try std.testing.expectEqual(5, soa_bytes(instruction.Instruction));
    try std.testing.expectEqual(1, @sizeOf(instruction.Opcode));
}
