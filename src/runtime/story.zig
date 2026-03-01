const std = @import("std");
const value = @import("value.zig");
const pointer_mod = @import("pointer.zig");
const json_loader = @import("json_loader.zig");
const state_mod = @import("state.zig");
const callstack_mod = @import("callstack.zig");
const evaluation = @import("evaluation.zig");

pub const RuntimeObject = value.RuntimeObject;
pub const Container = value.Container;
pub const ControlCommand = value.ControlCommand;
pub const NativeFunction = value.NativeFunction;
pub const PushPopType = value.PushPopType;
pub const Pointer = pointer_mod.Pointer;
pub const StoryState = state_mod.StoryState;
pub const Element = callstack_mod.Element;

pub const StepResult = enum { ok, stopped };

pub const Story = struct {
    root: *Container,
    state: StoryState,
    /// Arena owns the container tree (static content)
    arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,

    pub fn initFromJson(allocator: std.mem.Allocator, json_text: []const u8) !Story {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const loaded = try json_loader.loadStory(arena.allocator(), json_text);
        var st = try StoryState.init(allocator);
        errdefer st.deinit();

        // Set initial pointer to root container index 0
        st.call_stack.currentElement().current_pointer = .{
            .container = loaded.root,
            .index = 0,
        };

        var story = Story{
            .root = loaded.root,
            .state = st,
            .arena = arena,
            .allocator = allocator,
        };

        // Execute global declarations if present
        if (loaded.root.named_content.get("global decl")) |global_decl| {
            const saved_ptr = story.state.call_stack.currentElement().current_pointer;
            story.state.call_stack.currentElement().current_pointer = .{
                .container = global_decl,
                .index = 0,
            };
            while (true) {
                const r = try story.step();
                if (r == .stopped) break;
                if (story.state.call_stack.currentElement().current_pointer.isNull()) break;
            }
            story.state.call_stack.currentElement().current_pointer = saved_ptr;
            story.state.did_safe_exit = false;
            story.state.output_stream.clearRetainingCapacity();
        }

        return story;
    }

    pub fn deinit(self: *Story) void {
        self.state.deinit();
        self.arena.deinit();
    }

    fn currentElementConst(self: *const Story) *const Element {
        const cs = &self.state.call_stack;
        const thread = &cs.threads.items[cs.threads.items.len - 1];
        return &thread.call_stack.items[thread.call_stack.items.len - 1];
    }

    pub fn canContinue(self: *const Story) bool {
        return !self.currentElementConst().current_pointer.isNull() and !self.state.did_safe_exit;
    }

    /// Run until stopped and collect output. Caller owns the returned string.
    pub fn cont(self: *Story) ![]u8 {
        if (!self.canContinue()) return self.allocator.dupe(u8, "");

        self.state.output_stream.clearRetainingCapacity();
        self.state.did_safe_exit = false;

        while (self.canContinue()) {
            const result = try self.step();
            if (result == .stopped) break;
            // Implicit function return: if execution fell off the end of a named function
            // container the pointer becomes null while still inside a function frame.
            // Pop the frame and resume at the call site.
            if (self.state.call_stack.currentElement().current_pointer.isNull()) {
                if (self.state.call_stack.canPop(.function)) {
                    const fn_elem = self.state.call_stack.currentElement();
                    const fn_output_start = fn_elem.output_stream_index_at_push;
                    try self.state.call_stack.pop(.function);
                    trimNewlinesFromOutputStream(&self.state.output_stream);
                    trimLeadingNewlinesFromOutputStream(&self.state.output_stream, fn_output_start);
                    self.advancePointer();
                }
            }
        }

        return self.collectOutput();
    }

    fn collectOutput(self: *Story) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(self.allocator);

        var i: usize = 0;
        while (i < self.state.output_stream.items.len) : (i += 1) {
            const obj = self.state.output_stream.items[i];
            switch (obj) {
                .glue => {
                    // Trim trailing newlines from accumulated text
                    while (buf.items.len > 0 and buf.items[buf.items.len - 1] == '\n') {
                        buf.items.len -= 1;
                    }
                    // Skip any "\n" strings and chained glue that follow
                    while (i + 1 < self.state.output_stream.items.len) {
                        const next = self.state.output_stream.items[i + 1];
                        if (next == .glue) {
                            i += 1;
                        } else if (next == .string and std.mem.eql(u8, next.string, "\n")) {
                            i += 1;
                        } else {
                            break;
                        }
                    }
                },
                else => try appendObjectText(self.allocator, &buf, obj),
            }
        }

        return buf.toOwnedSlice(self.allocator);
    }

    fn appendObjectText(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), obj: RuntimeObject) !void {
        switch (obj) {
            .string => |s| try buf.appendSlice(allocator, s),
            .int => |n| {
                var tmp: [24]u8 = undefined;
                const s = std.fmt.bufPrint(&tmp, "{}", .{n}) catch unreachable;
                try buf.appendSlice(allocator, s);
            },
            .float => |f| try formatFloat(allocator, buf, f),
            .bool => |b| try buf.appendSlice(allocator, if (b) "1" else "0"),
            .void => {},
            else => {},
        }
    }

    fn formatFloat(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), f: f64) !void {
        // If integer-valued, print without decimal point
        if (f == @trunc(f) and @abs(f) < 1e15) {
            var tmp2: [24]u8 = undefined;
            const si = std.fmt.bufPrint(&tmp2, "{}", .{@as(i64, @intFromFloat(f))}) catch unreachable;
            try buf.appendSlice(allocator, si);
            return;
        }
        // Format to 7 significant digits by computing required decimal places from magnitude.
        const abs_f = @abs(f);
        const digits_before: usize = if (abs_f >= 1.0)
            @intFromFloat(@floor(@log10(abs_f)) + 1.0)
        else
            0;
        var tmp: [64]u8 = undefined;
        const prec = if (digits_before >= 7) @as(usize, 0) else 7 - digits_before;
        const s = switch (prec) {
            0 => try std.fmt.bufPrint(&tmp, "{d:.0}", .{f}),
            1 => try std.fmt.bufPrint(&tmp, "{d:.1}", .{f}),
            2 => try std.fmt.bufPrint(&tmp, "{d:.2}", .{f}),
            3 => try std.fmt.bufPrint(&tmp, "{d:.3}", .{f}),
            4 => try std.fmt.bufPrint(&tmp, "{d:.4}", .{f}),
            5 => try std.fmt.bufPrint(&tmp, "{d:.5}", .{f}),
            6 => try std.fmt.bufPrint(&tmp, "{d:.6}", .{f}),
            else => try std.fmt.bufPrint(&tmp, "{d:.7}", .{f}),
        };
        if (std.mem.indexOf(u8, s, ".")) |dot| {
            var end = s.len;
            while (end > dot + 2 and s[end - 1] == '0') end -= 1;
            try buf.appendSlice(allocator, s[0..end]);
        } else {
            try buf.appendSlice(allocator, s);
        }
    }

    /// Execute one step. Returns .ok to continue or .stopped to halt.
    pub fn step(self: *Story) !StepResult {
        const elem = self.state.call_stack.currentElement();
        const ptr = elem.current_pointer;

        if (ptr.isNull()) return .stopped;

        const container = ptr.container.?;
        const idx = ptr.index;
        if (idx < 0 or idx >= @as(i32, @intCast(container.content.len))) {
            // Past end: null out and stop
            elem.current_pointer = Pointer.null_value;
            return .stopped;
        }

        const obj = &container.content[@intCast(idx)];
        return try self.dispatchObject(obj);
    }

    fn dispatchObject(self: *Story, obj: *const RuntimeObject) !StepResult {
        const elem = self.state.call_stack.currentElement();

        switch (obj.*) {
            .container => |c| {
                self.recordVisitIfNeeded(c);
                elem.current_pointer = .{ .container = c, .index = 0 };
                return .ok;
            },
            .void => {
                if (elem.in_expression_evaluation) {
                    try self.state.evaluation_stack.append(self.allocator, .void);
                }
                self.advancePointer();
                return .ok;
            },
            .string => {
                if (elem.in_expression_evaluation) {
                    try self.state.evaluation_stack.append(self.allocator,obj.*);
                } else {
                    try self.state.output_stream.append(self.allocator,obj.*);
                }
                self.advancePointer();
                return .ok;
            },
            .int, .float, .bool => {
                if (elem.in_expression_evaluation) {
                    try self.state.evaluation_stack.append(self.allocator,obj.*);
                }
                self.advancePointer();
                return .ok;
            },
            .glue => {
                try self.state.output_stream.append(self.allocator,.glue);
                self.advancePointer();
                return .ok;
            },
            .divert_target => {
                if (elem.in_expression_evaluation) {
                    try self.state.evaluation_stack.append(self.allocator,obj.*);
                }
                self.advancePointer();
                return .ok;
            },
            .variable_pointer => {
                if (elem.in_expression_evaluation) {
                    try self.state.evaluation_stack.append(self.allocator,obj.*);
                }
                self.advancePointer();
                return .ok;
            },
            .control_command => |cmd| {
                return try self.handleControlCommand(cmd);
            },
            .native_function => |func| {
                try self.handleNativeFunction(func);
                self.advancePointer();
                return .ok;
            },
            .divert => |d| {
                return try self.handleDivert(d);
            },
            .variable_assignment => |va| {
                const val = self.state.evaluation_stack.pop() orelse .void;
                if (va.is_global) {
                    try self.state.variables_state.set(self.allocator, va.name, val);
                } else {
                    try elem.temporary_variables.set(self.allocator, va.name, val);
                }
                self.advancePointer();
                return .ok;
            },
            .variable_reference => |vr| {
                if (vr.path_for_count) |path| {
                    const count = self.state.visit_counts.get(path) orelse 0;
                    try self.state.evaluation_stack.append(self.allocator,.{ .int = @intCast(count) });
                } else {
                    const val = self.resolveVariable(vr.name) orelse .void;
                    try self.state.evaluation_stack.append(self.allocator,val);
                }
                self.advancePointer();
                return .ok;
            },
            .choice_point => {
                // Choice handling in a later task
                self.advancePointer();
                return .ok;
            },
            .list => {
                if (elem.in_expression_evaluation) {
                    try self.state.evaluation_stack.append(self.allocator, .void);
                }
                self.advancePointer();
                return .ok;
            },
        }
    }

    fn handleControlCommand(self: *Story, cmd: ControlCommand) !StepResult {
        const elem = self.state.call_stack.currentElement();
        switch (cmd) {
            .eval_start => {
                elem.in_expression_evaluation = true;
                self.advancePointer();
                return .ok;
            },
            .eval_end => {
                elem.in_expression_evaluation = false;
                self.advancePointer();
                return .ok;
            },
            .output => {
                const val = self.state.evaluation_stack.pop() orelse .void;
                try self.state.output_stream.append(self.allocator,val);
                self.advancePointer();
                return .ok;
            },
            .pop_eval_stack => {
                _ = self.state.evaluation_stack.pop();
                self.advancePointer();
                return .ok;
            },
            .duplicate => {
                if (self.state.evaluation_stack.items.len > 0) {
                    const top = self.state.evaluation_stack.items[self.state.evaluation_stack.items.len - 1];
                    try self.state.evaluation_stack.append(self.allocator,top);
                }
                self.advancePointer();
                return .ok;
            },
            .pop_function => {
                const fn_output_start = self.state.call_stack.currentElement().output_stream_index_at_push;
                try self.state.call_stack.pop(.function);
                // Trim trailing newlines the function body may have left in the output stream.
                // These are structural newlines from conditional blocks in pure computation functions.
                trimNewlinesFromOutputStream(&self.state.output_stream);
                trimLeadingNewlinesFromOutputStream(&self.state.output_stream, fn_output_start);
                self.advancePointer(); // advance past the function call divert
                return .ok;
            },
            .pop_tunnel => {
                try self.state.call_stack.pop(.tunnel);
                self.advancePointer(); // advance past the tunnel divert
                return .ok;
            },
            .begin_string => {
                elem.in_expression_evaluation = true;
                try self.state.output_stream.append(self.allocator,.{ .control_command = .begin_string });
                self.advancePointer();
                return .ok;
            },
            .end_string => {
                var text = std.ArrayList(u8).empty;
                defer text.deinit(self.allocator);
                // Find begin_string marker and collect strings after it
                var start: usize = self.state.output_stream.items.len;
                for (self.state.output_stream.items, 0..) |it, ki| {
                    if (it == .control_command and it.control_command == .begin_string) {
                        start = ki;
                    }
                }
                if (start >= self.state.output_stream.items.len) return error.MissingBeginString;
                for (self.state.output_stream.items[start + 1 ..]) |it| {
                    if (it == .string) try text.appendSlice(self.allocator, it.string);
                }
                self.state.output_stream.shrinkRetainingCapacity(start);
                const s = try text.toOwnedSlice(self.allocator);
                try self.state.evaluation_stack.append(self.allocator,.{ .string = s });
                elem.in_expression_evaluation = false;
                self.advancePointer();
                return .ok;
            },
            .no_op => {
                self.advancePointer();
                return .ok;
            },
            .done => {
                self.state.did_safe_exit = true;
                return .stopped;
            },
            .end_of_story => {
                return .stopped;
            },
            .seed_random => {
                const val = self.state.evaluation_stack.pop() orelse RuntimeObject{ .int = 0 };
                const seed: u32 = switch (val) {
                    .int => |n| @intCast(@abs(n)),
                    else => 0,
                };
                self.state.story_seed = seed;
                try self.state.evaluation_stack.append(self.allocator,.void);
                self.advancePointer();
                return .ok;
            },
            .visit_index => {
                const container = elem.current_pointer.container orelse {
                    try self.state.evaluation_stack.append(self.allocator,.{ .int = 0 });
                    self.advancePointer();
                    return .ok;
                };
                const count = self.state.visit_counts.get(container.path) orelse 0;
                // 0-based visit index
                const idx: i64 = if (count > 0) @intCast(count - 1) else 0;
                try self.state.evaluation_stack.append(self.allocator,.{ .int = idx });
                self.advancePointer();
                return .ok;
            },
            .turn_index => {
                try self.state.evaluation_stack.append(self.allocator,.{ .int = self.state.current_turn_index });
                self.advancePointer();
                return .ok;
            },
            .turns_since => {
                const val = self.state.evaluation_stack.pop() orelse .void;
                const path_str = switch (val) {
                    .divert_target => |p| p,
                    else => {
                        try self.state.evaluation_stack.append(self.allocator,.{ .int = -1 });
                        self.advancePointer();
                        return .ok;
                    },
                };
                const turn = self.state.turn_indices.get(path_str);
                const result: i64 = if (turn) |t| @intCast(self.state.current_turn_index - t) else -1;
                try self.state.evaluation_stack.append(self.allocator,.{ .int = result });
                self.advancePointer();
                return .ok;
            },
            .choice_count => {
                try self.state.evaluation_stack.append(self.allocator,.{
                    .int = @intCast(self.state.current_choices.items.len),
                });
                self.advancePointer();
                return .ok;
            },
            .sequence_shuffle_index => {
                const count_val = self.state.evaluation_stack.pop() orelse RuntimeObject{ .int = 1 };
                const count = switch (count_val) {
                    .int => |n| n,
                    else => 1,
                };
                const cur_container = elem.current_pointer.container orelse {
                    try self.state.evaluation_stack.append(self.allocator,.{ .int = 0 });
                    self.advancePointer();
                    return .ok;
                };
                const visits = self.state.visit_counts.get(cur_container.path) orelse 0;
                const idx: i64 = if (count > 0) @intCast(visits % @as(u32, @intCast(count))) else 0;
                try self.state.evaluation_stack.append(self.allocator,.{ .int = idx });
                self.advancePointer();
                return .ok;
            },
            .start_tag, .end_tag => {
                // Tags: stub for later
                self.advancePointer();
                return .ok;
            },
            .list_from_int, .list_range, .list_random => {
                // List stubs
                self.advancePointer();
                return .ok;
            },
            .begin_thread => {
                self.advancePointer();
                return .ok;
            },
        }
    }

    fn handleNativeFunction(self: *Story, func: NativeFunction) !void {
        // String concatenation requires allocator
        if (func == .add) {
            const len = self.state.evaluation_stack.items.len;
            if (len >= 2) {
                const rhs = self.state.evaluation_stack.items[len - 1];
                const lhs = self.state.evaluation_stack.items[len - 2];
                if (lhs == .string and rhs == .string) {
                    _ = self.state.evaluation_stack.pop();
                    _ = self.state.evaluation_stack.pop();
                    const joined = try std.mem.concat(self.allocator, u8, &.{ lhs.string, rhs.string });
                    try self.state.evaluation_stack.append(self.allocator,.{ .string = joined });
                    return;
                }
            }
        }
        try evaluation.callNativeFunction(self.allocator, func, &self.state.evaluation_stack);
    }

    fn handleDivert(self: *Story, d: value.Divert) !StepResult {
        const elem = self.state.call_stack.currentElement();

        // Conditional divert: pop condition, skip if false
        if (d.is_conditional) {
            const cond = self.state.evaluation_stack.pop() orelse RuntimeObject{ .bool = false };
            if (!evaluation.isTruthy(cond)) {
                self.advancePointer();
                return .ok;
            }
        }

        // Resolve target path (may be a variable)
        var target_path = d.target;
        if (d.is_variable) {
            const var_val = self.resolveVariable(d.target) orelse .void;
            switch (var_val) {
                .divert_target => |p| target_path = p,
                else => {
                    self.advancePointer();
                    return .ok;
                },
            }
        }

        // Resolve to pointer
        const target_ptr = self.resolvePath(target_path, elem.current_pointer) orelse {
            return error.DivertTargetNotFound;
        };
        const target_container = target_ptr.container orelse return error.DivertTargetNotFound;

        if (d.push_pop_type) |ppt| {
            // Function or tunnel call: save return point then jump
            const prev = elem.current_pointer;
            const stream_idx = self.state.output_stream.items.len;
            try self.state.call_stack.push(ppt, prev);
            self.recordVisitIfNeeded(target_container);
            const new_elem = self.state.call_stack.currentElement();
            new_elem.current_pointer = target_ptr;
            new_elem.output_stream_index_at_push = stream_idx;
        } else {
            // Plain divert: jump without return
            self.recordVisitIfNeeded(target_container);
            elem.current_pointer = target_ptr;
        }
        return .ok;
    }

    fn resolveVariable(self: *Story, name: []const u8) ?RuntimeObject {
        const thread = self.state.call_stack.currentThread();
        var i = thread.call_stack.items.len;
        while (i > 0) {
            i -= 1;
            if (thread.call_stack.items[i].temporary_variables.get(name)) |v| return v;
        }
        return self.state.variables_state.get(name);
    }

    /// Resolve a path string to a Pointer.
    ///
    /// Absolute paths (no leading '.') are resolved from root, targeting the container at index 0.
    ///
    /// Relative paths (leading '.') are resolved starting from `from_ptr`:
    ///   - The first '^' component steps from the INSTRUCTION LEVEL to `from_ptr.container`.
    ///   - Subsequent '^' components traverse `.parent` links.
    ///   - A numeric component that hits a sub-container enters it (index 0).
    ///   - A numeric component that hits a non-container returns {current_container, idx}.
    ///   - A name component does a named_content lookup.
    pub fn resolvePath(self: *const Story, path_str: []const u8, from_ptr: Pointer) ?Pointer {
        if (path_str.len == 0) return Pointer{ .container = self.root, .index = 0 };

        if (path_str[0] != '.') {
            // Absolute path: resolve container from root
            const c = resolveContainerAbs(self.root, path_str) orelse return null;
            return Pointer{ .container = c, .index = 0 };
        }

        // Relative path: first '^' jumps from instruction to its container.
        var current: ?*Container = null; // null = "instruction level"
        var iter = std.mem.splitScalar(u8, path_str[1..], '.');
        while (iter.next()) |part| {
            if (part.len == 0) continue;
            if (std.mem.eql(u8, part, "^")) {
                if (current == null) {
                    current = from_ptr.container orelse return null;
                } else {
                    current = current.?.parent orelse return null;
                }
            } else if (std.fmt.parseInt(u32, part, 10)) |idx| {
                const c = current orelse return null;
                if (idx >= c.content.len) return null;
                if (c.content[idx] == .container) {
                    current = c.content[idx].container;
                } else {
                    // Non-container index: execution position within current container
                    return Pointer{ .container = c, .index = @intCast(idx) };
                }
            } else |_| {
                const c = current orelse return null;
                current = c.named_content.get(part) orelse return null;
            }
        }
        return Pointer{ .container = current orelse return null, .index = 0 };
    }

    fn resolveContainerAbs(start: *Container, components_str: []const u8) ?*Container {
        var current: *Container = start;
        var iter = std.mem.splitScalar(u8, components_str, '.');
        while (iter.next()) |part| {
            if (part.len == 0) continue;
            if (std.fmt.parseInt(u32, part, 10)) |idx| {
                if (idx >= current.content.len) return null;
                if (current.content[idx] != .container) return null;
                current = current.content[idx].container;
            } else |_| {
                current = current.named_content.get(part) orelse return null;
            }
        }
        return current;
    }

    fn recordVisitIfNeeded(self: *Story, c: *Container) void {
        if (!c.flags.visits_should_be_counted) return;
        const entry = self.state.visit_counts.getOrPut(self.allocator, c.path) catch return;
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
        if (c.flags.turn_index_should_be_counted) {
            self.state.turn_indices.put(self.allocator, c.path, self.state.current_turn_index) catch {};
        }
    }

    /// Remove trailing "\n" RuntimeObjects from the output stream.
    /// Called after a function returns to discard structural newlines from conditional blocks.
    fn trimNewlinesFromOutputStream(stream: *std.ArrayList(RuntimeObject)) void {
        while (stream.items.len > 0) {
            const last = stream.items[stream.items.len - 1];
            if (last == .string and std.mem.eql(u8, last.string, "\n")) {
                stream.items.len -= 1;
            } else {
                break;
            }
        }
    }

    /// Remove leading "\n" RuntimeObjects from the function's portion of the output stream.
    /// `start` is the index at which the function began writing (saved at call time).
    fn trimLeadingNewlinesFromOutputStream(stream: *std.ArrayList(RuntimeObject), start: usize) void {
        var i = start;
        while (i < stream.items.len) {
            const item = stream.items[i];
            if (item == .string and std.mem.eql(u8, item.string, "\n")) {
                i += 1;
            } else {
                break;
            }
        }
        if (i > start) {
            // Shift remaining items down
            const count = i - start;
            const remaining = stream.items.len - i;
            std.mem.copyForwards(RuntimeObject, stream.items[start..start + remaining], stream.items[i..stream.items.len]);
            stream.items.len -= count;
        }
    }

    fn advancePointer(self: *Story) void {
        const elem = self.state.call_stack.currentElement();
        elem.current_pointer.index += 1;
        self.trimContainerEndIfNeeded();
    }

    /// Pop past ended containers, walking up the parent chain.
    fn trimContainerEndIfNeeded(self: *Story) void {
        const elem = self.state.call_stack.currentElement();
        var ptr = &elem.current_pointer;

        while (true) {
            const container = ptr.container orelse break;
            if (ptr.index < @as(i32, @intCast(container.content.len))) break;

            // Past end of this container — go to parent
            const idx_in_parent = container.index_in_parent;
            const parent = container.parent;

            if (idx_in_parent >= 0) {
                if (parent) |p| {
                    ptr.* = .{
                        .container = p,
                        .index = idx_in_parent + 1,
                    };
                    // Loop to check if we're also past end of parent
                    continue;
                }
            }

            // No parent or named-only: execution ends
            ptr.* = Pointer.null_value;
            break;
        }
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

fn readFixture(alloc: std.mem.Allocator, comptime rel_path: []const u8) ![]u8 {
    const builtin = @import("builtin");
    var threaded: std.Io.Threaded = if (builtin.single_threaded)
        .init_single_threaded
    else
        .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(io, "test/fixture/compiled/runtime/" ++ rel_path, alloc, .limited(256 * 1024));
}

test "Story hello_world" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "misc/hello_world.ink.json");
    defer alloc.free(json);

    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    try std.testing.expect(story.canContinue());
    const out = try story.cont();
    defer alloc.free(out);
    try std.testing.expectEqualStrings("Hello world\n", out);
    try std.testing.expect(!story.canContinue());
}

test "Story empty" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "misc/empty.ink.json");
    defer alloc.free(json);

    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    const out = try story.cont();
    defer alloc.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "Story arithmetic" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "evaluation/arithmetic.ink.json");
    defer alloc.free(json);

    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    const out = try story.cont();
    defer alloc.free(out);
    try std.testing.expectEqualStrings("36\n2\n3\n2\n2.333333\n8\n8\n", out);
}

test "Story boolean true" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "booleans/true.ink.json");
    defer alloc.free(json);

    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    const out = try story.cont();
    defer alloc.free(out);
    try std.testing.expectEqualStrings("1\n", out);
}

test "Story const variable" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "variables/const.ink.json");
    defer alloc.free(json);

    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    const out = try story.cont();
    defer alloc.free(out);
    try std.testing.expectEqualStrings("5\n", out);
}

test "Story factorial recursive" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "evaluation/factorial_recursive.ink.json");
    defer alloc.free(json);

    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    const out = try story.cont();
    defer alloc.free(out);
    try std.testing.expectEqualStrings("120\n", out);
}

test "Story basic tunnel" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "diverts/basic_tunnel.ink.json");
    defer alloc.free(json);

    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    const out = try story.cont();
    defer alloc.free(out);
    try std.testing.expectEqualStrings("Hello world\n", out);
}

test "Story not_true" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "booleans/not_true.ink.json");
    defer alloc.free(json);

    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    const out = try story.cont();
    defer alloc.free(out);
    try std.testing.expectEqualStrings("0\n", out);
}

test "Story three_greater_than_one" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "booleans/three_greater_than_one.ink.json");
    defer alloc.free(json);

    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    const out = try story.cont();
    defer alloc.free(out);
    try std.testing.expectEqualStrings("1\n", out);
}

test "Story true_plus_true" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "booleans/true_plus_true.ink.json");
    defer alloc.free(json);

    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    const out = try story.cont();
    defer alloc.free(out);
    try std.testing.expectEqualStrings("2\n", out);
}

test "Story simple_glue" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "glue/simple_glue.ink.json");
    defer alloc.free(json);

    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    const out = try story.cont();
    defer alloc.free(out);
    try std.testing.expectEqualStrings("Some content with glue.\n", out);
}

test "Story implicit_inline_glue" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "glue/implicit_inline_glue.ink.json");
    defer alloc.free(json);

    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    const out = try story.cont();
    defer alloc.free(out);
    // Function called inline should not introduce a spurious newline mid-line
    try std.testing.expectEqualStrings("I have five eggs.\n", out);
}
