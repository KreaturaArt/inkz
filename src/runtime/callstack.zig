const std = @import("std");
const value = @import("value.zig");
const pointer_mod = @import("pointer.zig");
const variables_mod = @import("variables.zig");

pub const PushPopType = value.PushPopType;
pub const Pointer = pointer_mod.Pointer;
pub const VariablesState = variables_mod.VariablesState;

pub const Element = struct {
    push_pop_type: ?PushPopType,
    current_pointer: Pointer,
    in_expression_evaluation: bool,
    temporary_variables: VariablesState,

    pub fn init(push_pop_type: ?PushPopType, ptr: Pointer) Element {
        return .{
            .push_pop_type = push_pop_type,
            .current_pointer = ptr,
            .in_expression_evaluation = false,
            .temporary_variables = VariablesState.init(),
        };
    }

    pub fn deinit(self: *Element, allocator: std.mem.Allocator) void {
        self.temporary_variables.deinit(allocator);
    }
};

pub const Thread = struct {
    call_stack: std.ArrayList(Element),
    thread_index: u32,
    previous_pointer: Pointer,

    pub fn init(allocator: std.mem.Allocator, index: u32) !Thread {
        var t = Thread{
            .call_stack = std.ArrayList(Element).empty,
            .thread_index = index,
            .previous_pointer = Pointer.null_value,
        };
        try t.call_stack.append(allocator, Element.init(null, Pointer.null_value));
        return t;
    }

    pub fn deinit(self: *Thread, allocator: std.mem.Allocator) void {
        for (self.call_stack.items) |*elem| elem.deinit(allocator);
        self.call_stack.deinit(allocator);
    }
};

pub const CallStack = struct {
    threads: std.ArrayList(Thread),
    thread_counter: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !CallStack {
        var cs = CallStack{
            .threads = std.ArrayList(Thread).empty,
            .thread_counter = 0,
            .allocator = allocator,
        };
        try cs.threads.append(allocator, try Thread.init(allocator, cs.thread_counter));
        cs.thread_counter += 1;
        return cs;
    }

    pub fn deinit(self: *CallStack) void {
        for (self.threads.items) |*t| t.deinit(self.allocator);
        self.threads.deinit(self.allocator);
    }

    pub fn currentThread(self: *CallStack) *Thread {
        return &self.threads.items[self.threads.items.len - 1];
    }

    pub fn currentElement(self: *CallStack) *Element {
        const t = self.currentThread();
        return &t.call_stack.items[t.call_stack.items.len - 1];
    }

    pub fn depth(self: *const CallStack) usize {
        var d: usize = 0;
        for (self.threads.items) |t| d += t.call_stack.items.len;
        return d;
    }

    pub fn push(self: *CallStack, ppt: PushPopType, ptr: Pointer) !void {
        try self.currentThread().call_stack.append(self.allocator, Element.init(ppt, ptr));
    }

    pub fn pop(self: *CallStack, ppt: PushPopType) !void {
        if (!self.canPop(ppt)) return error.CannotPop;
        var elem = self.currentThread().call_stack.pop().?;
        elem.deinit(self.allocator);
    }

    pub fn canPop(self: *const CallStack, ppt: PushPopType) bool {
        const t = &self.threads.items[self.threads.items.len - 1];
        if (t.call_stack.items.len <= 1) return false;
        const top = t.call_stack.items[t.call_stack.items.len - 1];
        return top.push_pop_type == ppt;
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "CallStack init" {
    const alloc = std.testing.allocator;
    var cs = try CallStack.init(alloc);
    defer cs.deinit();
    try std.testing.expectEqual(@as(?PushPopType, null), cs.currentElement().push_pop_type);
    try std.testing.expectEqual(@as(usize, 1), cs.depth());
}

test "CallStack push and pop" {
    const alloc = std.testing.allocator;
    var cs = try CallStack.init(alloc);
    defer cs.deinit();

    try cs.push(.function, Pointer.null_value);
    try std.testing.expectEqual(@as(usize, 2), cs.depth());
    try std.testing.expectEqual(PushPopType.function, cs.currentElement().push_pop_type.?);

    try cs.pop(.function);
    try std.testing.expectEqual(@as(usize, 1), cs.depth());
    try std.testing.expectEqual(@as(?PushPopType, null), cs.currentElement().push_pop_type);
}

test "CallStack mismatched pop" {
    const alloc = std.testing.allocator;
    var cs = try CallStack.init(alloc);
    defer cs.deinit();

    try cs.push(.function, Pointer.null_value);
    try std.testing.expectError(error.CannotPop, cs.pop(.tunnel));
    try cs.pop(.function);
}

test "CallStack canPop false at top level" {
    const alloc = std.testing.allocator;
    var cs = try CallStack.init(alloc);
    defer cs.deinit();
    try std.testing.expect(!cs.canPop(.function));
    try std.testing.expect(!cs.canPop(.tunnel));
}
