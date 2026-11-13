//! A stack over a fixed buffer. It never grows; pushing onto a full stack returns
//! `error.Overflow`, which callers translate into their named limit error, such as
//! `error.FrameLimit`. It replaces every unchecked `appendAssumeCapacity`.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const fault = @import("fault.zig");

pub fn BoundedStack(comptime T: type) type {
    comptime assert(@sizeOf(T) > 0);
    comptime assert(@sizeOf(T) <= 4096);
    return struct {
        buffer: []T,
        count: u32,
        /// The highest count since init: what the buffer actually needed.
        peak: u32 = 0,

        const Self = @This();

        pub const Fault = enum { ok, capacity_too_large, count_exceeds_capacity };

        /// Uses `buffer` as storage; the stack doesn't own it.
        pub fn init(buffer: []T) Self {
            const stack: Self = .{ .buffer = buffer, .count = 0 };
            assert(stack.capacity() == buffer.len);
            return stack;
        }

        /// Allocates `capacity_count` elements; free them with `deinit`.
        pub fn init_capacity(gpa: Allocator, capacity_count: u32) Allocator.Error!Self {
            const buffer = try gpa.alloc(T, capacity_count);
            const stack = init(buffer);
            assert(stack.capacity() == capacity_count);
            assert(stack.count == 0);
            return stack;
        }

        pub fn deinit(stack: *Self, gpa: Allocator) void {
            stack.verify();
            gpa.free(stack.buffer);
            stack.* = undefined;
            assert(@sizeOf(Self) > 0);
        }

        pub fn capacity(stack: *const Self) u32 {
            const result: u32 = @intCast(stack.buffer.len);
            assert(result == stack.buffer.len);
            assert(stack.count <= result);
            return result;
        }

        pub fn is_empty(stack: *const Self) bool {
            const result = stack.count == 0;
            assert(result == (stack.slice().len == 0));
            return result;
        }

        pub fn is_full(stack: *const Self) bool {
            const result = stack.count == stack.buffer.len;
            if (result) assert(stack.count == stack.capacity());
            return result;
        }

        pub fn push(stack: *Self, value: T) error{Overflow}!void {
            if (stack.is_full()) return error.Overflow;
            const count_before = stack.count;
            stack.buffer[stack.count] = value;
            stack.count += 1;
            stack.peak = @max(stack.peak, stack.count);
            assert(stack.count == count_before + 1);
        }

        /// Pushes all of `values`, or none of them if they don't fit.
        pub fn push_slice(stack: *Self, values: []const T) error{Overflow}!void {
            if (values.len > stack.buffer.len - stack.count) return error.Overflow;
            const count_before = stack.count;
            @memcpy(stack.buffer[stack.count..][0..values.len], values);
            stack.count += @intCast(values.len);
            stack.peak = @max(stack.peak, stack.count);
            assert(stack.count == count_before + values.len);
        }

        pub fn pop(stack: *Self) ?T {
            if (stack.count == 0) return null;
            stack.count -= 1;
            const value = stack.buffer[stack.count];
            assert(stack.count < stack.buffer.len);
            return value;
        }

        pub fn peek(stack: *const Self) ?T {
            if (stack.count == 0) return null;
            const value = stack.buffer[stack.count - 1];
            assert(stack.count > 0);
            return value;
        }

        /// A pointer to the top element; valid until the next push, pop or truncate.
        pub fn peek_pointer(stack: *Self) ?*T {
            if (stack.count == 0) return null;
            const pointer = &stack.buffer[stack.count - 1];
            assert(stack.count > 0);
            return pointer;
        }

        pub fn slice(stack: *const Self) []T {
            const items = stack.buffer[0..stack.count];
            assert(items.len == stack.count);
            return items;
        }

        /// Drops everything above `mark`, a count taken earlier. Used to undo work.
        pub fn truncate(stack: *Self, mark: u32) void {
            assert(mark <= stack.count);
            stack.count = mark;
        }

        pub fn clear(stack: *Self) void {
            stack.truncate(0);
            assert(stack.is_empty());
        }

        pub fn check(stack: *const Self) Fault {
            if (stack.buffer.len > std.math.maxInt(u32)) return .capacity_too_large;
            if (stack.count > stack.buffer.len) return .count_exceeds_capacity;
            return .ok;
        }

        pub fn verify(stack: *const Self) void {
            fault.verify(stack.check());
        }
    };
}

test "push and pop follow last-in first-out order" {
    // Basic stack behaviour: push three values and pop them back.
    var buffer: [4]u32 = undefined;
    var stack = BoundedStack(u32).init(&buffer);
    try stack.push(1);
    try stack.push(2);
    try stack.push(3);
    try std.testing.expectEqual(@as(?u32, 3), stack.peek());
    try std.testing.expectEqual(@as(?u32, 3), stack.pop());
    try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, stack.slice());
    try std.testing.expectEqual(@as(?u32, 2), stack.pop());
    try std.testing.expectEqual(@as(?u32, 1), stack.pop());
    try std.testing.expectEqual(@as(?u32, null), stack.pop());
}

test "overflow returns an error and leaves the stack unchanged" {
    // A full stack refuses more, for single pushes and slices: fill a stack of 2.
    var buffer: [2]u8 = undefined;
    var stack = BoundedStack(u8).init(&buffer);
    try stack.push_slice("ab");
    try std.testing.expectError(error.Overflow, stack.push('c'));
    stack.truncate(1);
    try std.testing.expectError(error.Overflow, stack.push_slice("cd"));
    try std.testing.expectEqualStrings("a", stack.slice());
}

test "truncate restores an earlier count" {
    // Marks undo speculative pushes (used for backtracking and lookahead): take
    // a mark, push more, truncate to the mark.
    const gpa = std.testing.allocator;
    var stack = try BoundedStack(u32).init_capacity(gpa, 8);
    defer stack.deinit(gpa);
    try stack.push(10);
    const mark = stack.count;
    try stack.push_slice(&.{ 20, 30, 40 });
    stack.truncate(mark);
    try std.testing.expectEqualSlices(u32, &.{10}, stack.slice());
    stack.clear();
    try std.testing.expect(stack.is_empty());
}

test "check reports a corrupted count" {
    // Negative space for verify: corrupt the count past the capacity.
    var buffer: [3]u32 = undefined;
    var stack = BoundedStack(u32).init(&buffer);
    try std.testing.expectEqual(BoundedStack(u32).Fault.ok, stack.check());
    stack.count = 4;
    try std.testing.expectEqual(BoundedStack(u32).Fault.count_exceeds_capacity, stack.check());
}

test "the peak remembers the highest count" {
    // The usage measurement: push, pop and push_slice; clearing keeps it.
    var buffer: [8]u32 = undefined;
    var stack = BoundedStack(u32).init(&buffer);
    try stack.push(1);
    try stack.push(2);
    try stack.push(3);
    _ = stack.pop();
    try std.testing.expectEqual(@as(u32, 3), stack.peak);
    try stack.push_slice(&.{ 4, 5, 6 });
    stack.clear();
    try std.testing.expectEqual(@as(u32, 5), stack.peak);
}
