//! An explicit stack for traversals that would otherwise recurse (plan D9). It is a
//! `BoundedStack` plus a step bound: every pop counts as one step, and a traversal that takes
//! more than `steps_max` steps returns `error.WorkLimit` instead of looping forever. Nesting
//! deeper than the capacity returns `error.WorkLimit` too, never undefined behaviour.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const BoundedStack = @import("bounded_stack.zig").BoundedStack;

pub fn WorkStack(comptime T: type) type {
    comptime assert(@sizeOf(T) > 0);
    return struct {
        stack: BoundedStack(T),
        steps: u32,
        steps_max: u32,

        const Self = @This();

        pub const Options = struct {
            depth_max: u32,
            steps_max: u32,
        };

        pub fn init(gpa: Allocator, options: Options) Allocator.Error!Self {
            assert(options.depth_max > 0);
            assert(options.steps_max > 0);
            const stack = try BoundedStack(T).init_capacity(gpa, options.depth_max);
            return .{ .stack = stack, .steps = 0, .steps_max = options.steps_max };
        }

        pub fn deinit(work: *Self, gpa: Allocator) void {
            assert(work.steps <= work.steps_max);
            work.stack.deinit(gpa);
            work.* = undefined;
        }

        pub fn push(work: *Self, item: T) error{WorkLimit}!void {
            assert(work.steps <= work.steps_max);
            work.stack.push(item) catch return error.WorkLimit;
            assert(!work.stack.is_empty());
        }

        /// The next item to visit, or null when the traversal is done.
        pub fn pop(work: *Self) error{WorkLimit}!?T {
            assert(work.steps <= work.steps_max);
            const item = work.stack.pop() orelse return null;
            if (work.steps == work.steps_max) return error.WorkLimit;
            work.steps += 1;
            assert(work.steps <= work.steps_max);
            return item;
        }

        pub fn depth(work: *const Self) u32 {
            assert(work.steps <= work.steps_max);
            const count = work.stack.count;
            assert(count <= work.stack.capacity());
            return count;
        }
    };
}

test "a tree is traversed depth-first without recursion" {
    // Goal: the stack replaces recursion. Method: visit a small tree stored as child lists,
    // pushing children in reverse so they come out in order.
    const gpa = std.testing.allocator;
    const children = [_][]const u32{ &.{ 1, 2 }, &.{3}, &.{}, &.{} };
    var work = try WorkStack(u32).init(gpa, .{ .depth_max = 4, .steps_max = 16 });
    defer work.deinit(gpa);
    try work.push(0);
    var order: [4]u32 = undefined;
    var visited: u32 = 0;
    while (try work.pop()) |node| {
        order[visited] = node;
        visited += 1;
        var child_index = children[node].len;
        while (child_index > 0) {
            child_index -= 1;
            try work.push(children[node][child_index]);
        }
    }
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 3, 2 }, order[0..visited]);
}

test "too deep or too long traversals return WorkLimit" {
    // Goal: both bounds hold. Method: overfill the depth, then loop past the step bound.
    const gpa = std.testing.allocator;
    var shallow = try WorkStack(u32).init(gpa, .{ .depth_max = 2, .steps_max = 100 });
    defer shallow.deinit(gpa);
    try shallow.push(1);
    try shallow.push(2);
    try std.testing.expectError(error.WorkLimit, shallow.push(3));

    var short = try WorkStack(u32).init(gpa, .{ .depth_max = 2, .steps_max = 3 });
    defer short.deinit(gpa);
    try short.push(0);
    try std.testing.expectError(error.WorkLimit, visit_cycle(&short));
}

/// A traversal over a cycle: every node pushes itself again, so only the step bound ends it.
fn visit_cycle(work: *WorkStack(u32)) error{WorkLimit}!void {
    assert(work.depth() == 1);
    assert(work.steps == 0);
    while (try work.pop()) |node| try work.push(node);
}
