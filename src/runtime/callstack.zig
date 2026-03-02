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
    /// Index into the output_stream at the time this frame was pushed.
    /// Used to trim leading newlines from a function's text output on return.
    output_stream_index_at_push: usize,

    pub fn init(push_pop_type: ?PushPopType, ptr: Pointer) Element {
        return .{
            .push_pop_type = push_pop_type,
            .current_pointer = ptr,
            .in_expression_evaluation = false,
            .temporary_variables = VariablesState.init(),
            .output_stream_index_at_push = 0,
        };
    }

    pub fn deinit(self: *Element, allocator: std.mem.Allocator) void {
        self.temporary_variables.deinit(allocator);
    }

    pub fn clone(self: *const Element, allocator: std.mem.Allocator) !Element {
        return .{
            .push_pop_type = self.push_pop_type,
            .current_pointer = self.current_pointer,
            .in_expression_evaluation = self.in_expression_evaluation,
            .temporary_variables = try self.temporary_variables.clone(allocator),
            .output_stream_index_at_push = self.output_stream_index_at_push,
        };
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

    pub fn clone(self: *const Thread, allocator: std.mem.Allocator, new_index: u32) !Thread {
        var new_thread = Thread{
            .call_stack = std.ArrayList(Element).empty,
            .thread_index = new_index,
            .previous_pointer = self.previous_pointer,
        };
        for (self.call_stack.items) |elem| {
            try new_thread.call_stack.append(allocator, try elem.clone(allocator));
        }
        return new_thread;
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

    pub fn canPopThread(self: *const CallStack) bool {
        return self.threads.items.len > 1;
    }

    /// Clone the current (last) thread and make the clone the new current thread.
    pub fn pushThread(self: *CallStack) !void {
        const new_thread = try self.currentThread().clone(self.allocator, self.thread_counter);
        self.thread_counter += 1;
        try self.threads.append(self.allocator, new_thread);
    }

    /// Pop (and deinit) the current thread; resumes the previous thread.
    pub fn popThread(self: *CallStack) !void {
        if (!self.canPopThread()) return error.CannotPopThread;
        var t = self.threads.pop().?;
        t.deinit(self.allocator);
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
