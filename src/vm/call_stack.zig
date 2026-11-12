//! The call stack (plan §4.5, P4.4), as ink's CallStack.cs but flat: every thread's frames sit
//! in one array, each thread a range of it, and every frame's temps sit in one array, each
//! frame a range of it. Only the current (last) thread's top frame ever grows, so pushes and
//! new temps always append, and forking a thread is a range copy.
//!
//! A context index is ink's: frame position + 1 within the current thread, or 0 for globals.

const std = @import("std");
const assert = std.debug.assert;
const index = @import("../core/index.zig");
const limits = @import("../core/limits.zig");
const fault = @import("../core/fault.zig");
const BoundedStack = @import("../core/bounded_stack.zig").BoundedStack;
const Value = @import("value.zig").Value;
const ContainerIndex = index.ContainerIndex;
const StringId = index.StringId;

/// A position in the program: content `index` of `container`. The null pointer has no
/// container.
pub const Pointer = struct {
    container: ContainerIndex,
    index: u32,

    pub const @"null": Pointer = .{ .container = .none, .index = 0 };
    /// The index of a pointer at the container itself (ink's index -1), as loaded saves
    /// give previous pointers; it resolves to no item.
    pub const container_self: u32 = std.math.maxInt(u32);

    pub fn is_null(pointer: Pointer) bool {
        assert(@sizeOf(Pointer) == 8);
        const result = pointer.container.is_none();
        assert(!result or pointer.index == 0);
        return result;
    }

    pub fn start_of(container: ContainerIndex) Pointer {
        assert(container.to_int() < std.math.maxInt(u32));
        assert(!container.is_none());
        return .{ .container = container, .index = 0 };
    }
};

/// ink's PushPopType, with its numbers (they appear in saves).
pub const FrameKind = enum(u8) { tunnel = 0, function = 1, function_evaluation_from_game = 2 };

pub const Frame = struct {
    pointer: Pointer,
    temps_first: u32,
    evaluation_height: u32,
    /// ink's functionStartInOutputStream: where this function's output began (plan S10).
    function_start_in_output: u32,
    temps_count: u16,
    kind: FrameKind,
    in_expression_evaluation: bool,
};

pub const Thread = struct {
    frame_first: u32,
    frame_count: u32,
    /// ink's threadIndex: a counter value, unique among live threads.
    counter: u32,
    previous_pointer: Pointer,
};

pub const Temp = struct {
    name: StringId,
    value: Value,
};

comptime {
    assert(@sizeOf(Frame) == limits.element_bytes.frame);
    assert(@sizeOf(Thread) == limits.element_bytes.thread);
    assert(@sizeOf(Temp) == limits.element_bytes.temp);
}

pub const Error = error{ FrameLimit, ThreadLimit, TempLimit, MismatchedPop, CannotPopThread };

pub const CallStack = struct {
    frames: BoundedStack(Frame),
    threads: BoundedStack(Thread),
    temps: BoundedStack(Temp),
    temps_per_frame_max: u32,
    thread_counter: u32 = 0,

    pub const Fault = enum {
        ok,
        no_threads,
        thread_without_frames,
        threads_not_contiguous,
        frames_not_covered,
        temps_not_contiguous,
        temps_not_covered,
        storage,
    };

    pub fn init(
        frames: []Frame,
        threads: []Thread,
        temps: []Temp,
        temps_per_frame_max: u32,
    ) CallStack {
        assert(frames.len > 0 and threads.len > 0);
        assert(temps_per_frame_max <= std.math.maxInt(u16));
        return .{
            .frames = .init(frames),
            .threads = .init(threads),
            .temps = .init(temps),
            .temps_per_frame_max = temps_per_frame_max,
        };
    }

    /// One thread with one tunnel frame at `start`, as ink's Reset.
    pub fn reset(call_stack: *CallStack, start: Pointer) void {
        assert(!start.is_null());
        call_stack.frames.clear();
        call_stack.threads.clear();
        call_stack.temps.clear();
        call_stack.thread_counter = 0;
        call_stack.threads.push(.{
            .frame_first = 0,
            .frame_count = 1,
            .counter = 0,
            .previous_pointer = .null,
        }) catch unreachable;
        call_stack.frames.push(.{
            .pointer = start,
            .temps_first = 0,
            .evaluation_height = 0,
            .function_start_in_output = 0,
            .temps_count = 0,
            .kind = .tunnel,
            .in_expression_evaluation = false,
        }) catch unreachable;
        call_stack.verify();
    }

    pub fn current_thread(call_stack: *CallStack) *Thread {
        assert(!call_stack.threads.is_empty());
        const thread = call_stack.threads.peek_pointer().?;
        assert(thread.frame_count > 0);
        return thread;
    }

    /// The frames of the current thread, bottom first.
    pub fn current_frames(call_stack: *CallStack) []Frame {
        assert(call_stack.frames.count <= call_stack.frames.buffer.len);
        const thread = call_stack.current_thread();
        const frames = call_stack.frames.slice()[thread.frame_first..][0..thread.frame_count];
        assert(thread.frame_first + thread.frame_count == call_stack.frames.count);
        return frames;
    }

    pub fn current_frame(call_stack: *CallStack) *Frame {
        assert(call_stack.frames.count <= call_stack.frames.buffer.len);
        const frames = call_stack.current_frames();
        assert(frames.len > 0);
        return &frames[frames.len - 1];
    }

    /// Frames in the current thread: ink's `depth`.
    pub fn depth(call_stack: *CallStack) u32 {
        assert(call_stack.frames.count <= call_stack.frames.buffer.len);
        const count = call_stack.current_thread().frame_count;
        assert(count > 0);
        return count;
    }

    /// The frame of context `context` (1-based), or the current frame for -1.
    fn frame_for_context(call_stack: *CallStack, context: i32) *Frame {
        assert(call_stack.frames.count <= call_stack.frames.buffer.len);
        const frames = call_stack.current_frames();
        assert(context == -1 or (context >= 1 and context <= frames.len));
        const position: usize = if (context == -1) frames.len - 1 else @intCast(context - 1);
        return &frames[position];
    }

    pub fn can_pop(call_stack: *CallStack, kind: ?FrameKind) bool {
        assert(call_stack.frames.count <= call_stack.frames.buffer.len);
        if (call_stack.depth() <= 1) return false;
        const result = if (kind) |wanted| call_stack.current_frame().kind == wanted else true;
        assert(call_stack.depth() > 1);
        return result;
    }

    /// A new frame continuing from the current pointer (ink's Push).
    pub fn push(
        call_stack: *CallStack,
        kind: FrameKind,
        evaluation_height: u32,
        output_length: u32,
    ) Error!void {
        assert(call_stack.threads.count > 0);
        const pointer = call_stack.current_frame().pointer;
        call_stack.frames.push(.{
            .pointer = pointer,
            .temps_first = call_stack.temps.count,
            .evaluation_height = evaluation_height,
            .function_start_in_output = output_length,
            .temps_count = 0,
            .kind = kind,
            .in_expression_evaluation = false,
        }) catch return error.FrameLimit;
        call_stack.current_thread().frame_count += 1;
        assert(call_stack.current_frame().kind == kind);
    }

    pub fn pop(call_stack: *CallStack, kind: ?FrameKind) Error!void {
        assert(call_stack.frames.count <= call_stack.frames.buffer.len);
        if (!call_stack.can_pop(kind)) return error.MismatchedPop;
        const frame = call_stack.frames.pop().?;
        call_stack.temps.truncate(frame.temps_first);
        call_stack.current_thread().frame_count -= 1;
        assert(call_stack.temps.count == frame.temps_first);
    }

    /// A copy of the current thread becomes the current thread (ink's PushThread).
    pub fn push_thread(call_stack: *CallStack) Error!void {
        assert(call_stack.frames.count <= call_stack.frames.buffer.len);
        const source = call_stack.current_thread().*;
        if (call_stack.threads.is_full()) return error.ThreadLimit;
        try call_stack.copy_thread(source, call_stack.frames.count);
        assert(call_stack.current_thread().counter == call_stack.thread_counter);
    }

    /// Appends a copy of `source` (frames and their temps) as the new current thread.
    fn copy_thread(call_stack: *CallStack, source: Thread, frame_first: u32) Error!void {
        assert(source.frame_count > 0);
        assert(frame_first == call_stack.frames.count);
        const frames_mark = call_stack.frames.count;
        const temps_mark = call_stack.temps.count;
        errdefer call_stack.frames.truncate(frames_mark);
        errdefer call_stack.temps.truncate(temps_mark);
        for (0..source.frame_count) |offset| {
            var frame = call_stack.frames.slice()[source.frame_first + offset];
            const temps = call_stack.temps.slice()[frame.temps_first..][0..frame.temps_count];
            frame.temps_first = call_stack.temps.count;
            call_stack.temps.push_slice(temps) catch return error.TempLimit;
            call_stack.frames.push(frame) catch return error.FrameLimit;
        }
        call_stack.thread_counter += 1;
        call_stack.threads.push(.{
            .frame_first = frame_first,
            .frame_count = source.frame_count,
            .counter = call_stack.thread_counter,
            .previous_pointer = source.previous_pointer,
        }) catch return error.ThreadLimit;
    }

    /// ink's canPopThread: more than one thread, and not inside a function the game called.
    pub fn can_pop_thread(call_stack: *CallStack) bool {
        assert(call_stack.frames.count <= call_stack.frames.buffer.len);
        const result = call_stack.threads.count > 1 and
            call_stack.current_frame().kind != .function_evaluation_from_game;
        assert(!result or call_stack.threads.count > 1);
        return result;
    }

    pub fn pop_thread(call_stack: *CallStack) Error!void {
        assert(call_stack.frames.count <= call_stack.frames.buffer.len);
        if (!call_stack.can_pop_thread()) return error.CannotPopThread;
        const thread = call_stack.threads.pop().?;
        const temps_first = call_stack.frames.slice()[thread.frame_first].temps_first;
        call_stack.frames.truncate(thread.frame_first);
        call_stack.temps.truncate(temps_first);
        const current = call_stack.current_thread();
        assert(current.frame_first + current.frame_count == call_stack.frames.count);
    }

    /// A temp of context `context` (-1 for the current frame).
    pub fn temp_get(call_stack: *CallStack, name: StringId, context: i32) ?Value {
        assert(!name.is_none());
        const frame = call_stack.frame_for_context(context);
        const temps = call_stack.temps.slice()[frame.temps_first..][0..frame.temps_count];
        assert(frame.temps_count <= call_stack.temps_per_frame_max);
        for (temps) |temp| {
            if (temp.name == name) return temp.value;
        }
        return null;
    }

    /// Sets a temp; with `declare_new`, adds it to the frame if it isn't there yet. Only the
    /// current frame can gain temps, as only it declares them.
    pub fn temp_set(
        call_stack: *CallStack,
        name: StringId,
        value: Value,
        declare_new: bool,
        context: i32,
    ) (Error || error{TempNotFound})!void {
        assert(!name.is_none());
        const frame = call_stack.frame_for_context(context);
        const temps = call_stack.temps.slice()[frame.temps_first..][0..frame.temps_count];
        for (temps) |*temp| {
            if (temp.name == name) {
                temp.value = value;
                return;
            }
        }
        if (!declare_new) return error.TempNotFound;
        assert(frame == call_stack.current_frame());
        if (frame.temps_count == call_stack.temps_per_frame_max) return error.TempLimit;
        call_stack.temps.push(.{ .name = name, .value = value }) catch return error.TempLimit;
        frame.temps_count += 1;
    }

    /// ink's ContextForVariableNamed: the current frame's context if it has the temp, else 0.
    pub fn context_for(call_stack: *CallStack, name: StringId) i32 {
        assert(!name.is_none());
        const depth_now = call_stack.depth();
        const has = call_stack.temp_get(name, -1) != null;
        assert(depth_now > 0);
        return if (has) @intCast(depth_now) else 0;
    }

    pub fn check(call_stack: *const CallStack) Fault {
        assert(call_stack.temps_per_frame_max > 0);
        if (call_stack.frames.check() != .ok or call_stack.threads.check() != .ok) return .storage;
        if (call_stack.temps.check() != .ok) return .storage;
        const threads = call_stack.threads.buffer[0..call_stack.threads.count];
        if (threads.len == 0) return .no_threads;
        var next_frame: u32 = 0;
        for (threads) |thread| {
            if (thread.frame_count == 0) return .thread_without_frames;
            if (thread.frame_first != next_frame) return .threads_not_contiguous;
            next_frame += thread.frame_count;
        }
        if (next_frame != call_stack.frames.count) return .frames_not_covered;
        const result = call_stack.check_temps();
        assert(result != .storage);
        return result;
    }

    fn check_temps(call_stack: *const CallStack) Fault {
        assert(call_stack.temps_per_frame_max > 0);
        const frames = call_stack.frames.buffer[0..call_stack.frames.count];
        var next_temp: u32 = 0;
        for (frames) |frame| {
            if (frame.temps_first != next_temp) return .temps_not_contiguous;
            if (frame.temps_count > call_stack.temps_per_frame_max) return .temps_not_contiguous;
            next_temp += frame.temps_count;
        }
        if (next_temp != call_stack.temps.count) return .temps_not_covered;
        assert(next_temp <= call_stack.temps.buffer.len);
        return .ok;
    }

    pub fn verify(call_stack: *const CallStack) void {
        assert(call_stack.temps_per_frame_max > 0);
        fault.verify(call_stack.check());
    }
};

const TestStorage = struct {
    frames: [8]Frame = undefined,
    threads: [4]Thread = undefined,
    temps: [16]Temp = undefined,

    fn call_stack(storage: *TestStorage) CallStack {
        var result = CallStack.init(&storage.frames, &storage.threads, &storage.temps, 4);
        result.reset(.start_of(.from_int(0)));
        assert(result.depth() == 1);
        assert(result.threads.count == 1);
        return result;
    }
};

const x: StringId = .from_int(1);
const y: StringId = .from_int(2);

test "frames push and pop, and temps belong to their frame" {
    // Goal: P4.4. Method: temps in two frames, lookups by context, then pop.
    var storage: TestStorage = .{};
    var stack = storage.call_stack();
    try stack.temp_set(x, .{ .integer = 1 }, true, -1);
    try stack.push(.function, 3, 10);
    try stack.temp_set(x, .{ .integer = 2 }, true, -1);
    try std.testing.expectEqual(Value{ .integer = 2 }, stack.temp_get(x, -1).?);
    try std.testing.expectEqual(Value{ .integer = 1 }, stack.temp_get(x, 1).?);
    try std.testing.expectEqual(@as(i32, 2), stack.context_for(x));
    try std.testing.expectEqual(@as(i32, 0), stack.context_for(y));
    // A reference parameter assigns the caller's existing temp.
    try stack.temp_set(x, .{ .integer = 9 }, false, 1);
    try std.testing.expectError(error.TempNotFound, stack.temp_set(y, .null, false, 1));
    try std.testing.expectError(error.MismatchedPop, stack.pop(.tunnel));
    try stack.pop(.function);
    try std.testing.expectEqual(Value{ .integer = 9 }, stack.temp_get(x, -1).?);
    try std.testing.expectError(error.MismatchedPop, stack.pop(null));
    stack.verify();
}

test "a forked thread copies frames and temps, and popping it restores the state" {
    // Goal: P4.4; fork by range copy. Method: fork, change the fork, pop it, compare.
    var storage: TestStorage = .{};
    var stack = storage.call_stack();
    try stack.temp_set(x, .{ .integer = 1 }, true, -1);
    try stack.push(.tunnel, 0, 0);
    try stack.temp_set(y, .{ .integer = 2 }, true, -1);
    try stack.push_thread();
    try std.testing.expectEqual(@as(u32, 2), stack.threads.count);
    try std.testing.expectEqual(@as(u32, 1), stack.current_thread().counter);
    try stack.temp_set(y, .{ .integer = 20 }, false, -1);
    try stack.push(.function, 0, 0);
    stack.verify();
    try stack.pop_thread();
    try std.testing.expectEqual(@as(u32, 2), stack.depth());
    try std.testing.expectEqual(Value{ .integer = 2 }, stack.temp_get(y, -1).?);
    try std.testing.expectEqual(@as(u32, 2), stack.temps.count);
    try std.testing.expectError(error.CannotPopThread, stack.pop_thread());
    stack.verify();
}

test "every limit returns its named error" {
    // Goal: negative space for P4.4. Method: exhaust frames, temps per frame, and threads.
    var storage: TestStorage = .{};
    var stack = storage.call_stack();
    for (0..7) |_| try stack.push(.tunnel, 0, 0);
    try std.testing.expectError(error.FrameLimit, stack.push(.tunnel, 0, 0));
    for (0..7) |_| try stack.pop(.tunnel);
    for (1..5) |name| try stack.temp_set(.from_int(@intCast(name)), .null, true, -1);
    try std.testing.expectError(error.TempLimit, stack.temp_set(.from_int(9), .null, true, -1));
    var small: TestStorage = .{};
    var threads_stack = CallStack.init(&small.frames, small.threads[0..1], &small.temps, 4);
    threads_stack.reset(.start_of(.from_int(0)));
    try std.testing.expectError(error.ThreadLimit, threads_stack.push_thread());
}

test "check reports a corrupted call stack" {
    // Goal: negative space (D20). Method: break thread and temp ranges.
    var storage: TestStorage = .{};
    var stack = storage.call_stack();
    try stack.push(.function, 0, 0);
    try std.testing.expectEqual(CallStack.Fault.ok, stack.check());
    storage.threads[0].frame_count = 1;
    try std.testing.expectEqual(CallStack.Fault.frames_not_covered, stack.check());
    storage.threads[0].frame_count = 2;
    storage.frames[1].temps_first = 3;
    try std.testing.expectEqual(CallStack.Fault.temps_not_contiguous, stack.check());
}
