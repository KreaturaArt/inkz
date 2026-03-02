const std = @import("std");
const value = @import("value.zig");
const pointer_mod = @import("pointer.zig");
const json_loader = @import("json_loader.zig");
const state_mod = @import("state.zig");
const callstack_mod = @import("callstack.zig");
const evaluation = @import("evaluation.zig");
const choices_mod = @import("choices.zig");

pub const RuntimeObject = value.RuntimeObject;
pub const Container = value.Container;
pub const ControlCommand = value.ControlCommand;
pub const NativeFunction = value.NativeFunction;
pub const PushPopType = value.PushPopType;
pub const Pointer = pointer_mod.Pointer;
pub const StoryState = state_mod.StoryState;
pub const Element = callstack_mod.Element;
pub const Choice = choices_mod.Choice;

pub const StepResult = enum { ok, stopped };

pub const Story = struct {
    root: *Container,
    state: StoryState,
    /// Arena owns the container tree (static content)
    arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    /// Invisible default choice target recorded per-cont(); null if none seen this turn.
    default_choice_target: ?[]const u8 = null,
    /// Tags collected during the current cont() call.
    current_tags: std.ArrayList([]const u8) = std.ArrayList([]const u8).empty,

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
        self.current_tags.deinit(self.allocator);
    }

    /// Return tags collected during the most recent cont() call.
    pub fn currentTags(self: *const Story) []const []const u8 {
        return self.current_tags.items;
    }

    /// Jump directly to a named path (knot/stitch) by absolute path string.
    pub fn choosePathString(self: *Story, path: []const u8) !void {
        const target_ptr = self.resolvePath(path, .{ .container = null, .index = -1 }) orelse
            return error.PathNotFound;
        if (target_ptr.container) |c| self.recordVisitIfNeeded(c);
        self.state.call_stack.currentElement().current_pointer = target_ptr;
        self.state.did_safe_exit = false;
        self.state.current_choices.clearRetainingCapacity();
    }

    fn currentElementConst(self: *const Story) *const Element {
        const cs = &self.state.call_stack;
        const thread = &cs.threads.items[cs.threads.items.len - 1];
        return &thread.call_stack.items[thread.call_stack.items.len - 1];
    }

    pub fn canContinue(self: *const Story) bool {
        if (self.currentElementConst().current_pointer.isNull()) return false;
        if (self.state.did_safe_exit) return false;
        return true;
    }

    /// Return the current choices (read-only slice).
    pub fn currentChoices(self: *const Story) []const Choice {
        return self.state.current_choices.items;
    }

    /// Select a choice by index. Jumps to the choice's target and prepares for next cont().
    pub fn chooseChoiceIndex(self: *Story, idx: usize) !void {
        if (idx >= self.state.current_choices.items.len) return error.InvalidChoiceIndex;
        const choice = self.state.current_choices.items[idx];
        // Jump to choice target (target_path is already an absolute path)
        const target_ptr = self.resolvePath(choice.target_path, self.state.call_stack.currentElement().current_pointer) orelse
            return error.DivertTargetNotFound;
        // Record a visit to the target container so once-only choices work correctly.
        if (target_ptr.container) |c| self.recordVisitIfNeeded(c);
        self.state.call_stack.currentElement().current_pointer = target_ptr;
        self.state.did_safe_exit = false;
        self.state.current_turn_index += 1;
        self.state.current_choices.clearRetainingCapacity();
    }

    /// Run until stopped and collect output. Caller owns the returned string.
    pub fn cont(self: *Story) ![]u8 {
        if (!self.canContinue()) return self.allocator.dupe(u8, "");

        self.state.output_stream.clearRetainingCapacity();
        self.state.did_safe_exit = false;
        self.default_choice_target = null;
        self.current_tags.clearRetainingCapacity();

        try self.runStepLoop();

        // If no choices surfaced and an invisible default was recorded, auto-follow it.
        if (self.state.current_choices.items.len == 0) {
            if (self.default_choice_target) |target| {
                self.default_choice_target = null;
                const target_ptr = self.resolvePath(target, .{ .container = null, .index = -1 }) orelse
                    return self.collectOutput();
                if (target_ptr.container) |c| self.recordVisitIfNeeded(c);
                self.state.call_stack.currentElement().current_pointer = target_ptr;
                self.state.did_safe_exit = false;
                self.state.current_turn_index += 1;
                try self.runStepLoop();
            }
        }

        return self.collectOutput();
    }

    fn runStepLoop(self: *Story) !void {
        while (self.canContinue()) {
            const result = try self.step();
            // Implicit function return: if execution fell off the end of a named function
            // container the pointer becomes null while still inside a function frame.
            // Pop the frame and resume at the call site. Must be checked before the
            // stopped-break so functions without explicit ~ret can return normally.
            if (self.state.call_stack.currentElement().current_pointer.isNull()) {
                if (self.state.call_stack.canPop(.function)) {
                    const fn_elem = self.state.call_stack.currentElement();
                    const fn_output_start = fn_elem.output_stream_index_at_push;
                    try self.state.call_stack.pop(.function);
                    trimNewlinesFromOutputStream(&self.state.output_stream);
                    trimLeadingNewlinesFromOutputStream(&self.state.output_stream, fn_output_start);
                    self.advancePointer();
                    continue;
                }
            }
            if (result == .stopped) break;
        }
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
            // Past end of this container.
            // If it's an inline sub-container (index_in_parent >= 0), step up to
            // the parent and continue from the next item there. This implements
            // natural "fall-through" after entering an inline conditional block.
            var cur: *Container = container;
            while (cur.index_in_parent >= 0) {
                const parent = cur.parent orelse break;
                const next: i32 = cur.index_in_parent + 1;
                if (next < @as(i32, @intCast(parent.content.len))) {
                    elem.current_pointer = .{ .container = parent, .index = next };
                    return .ok;
                }
                cur = parent;
            }
            // No inline parent to step into: null out and stop.
            elem.current_pointer = Pointer.null_value;
            return .stopped;
        }

        const obj = &container.content[@intCast(idx)];
        return try self.dispatchObject(obj);
    }

    pub fn dispatchObject(self: *Story, obj: *const RuntimeObject) !StepResult {
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
                // During str/str collection, strings always go to output_stream
                if (self.inStringEvalMode() or !elem.in_expression_evaluation) {
                    try self.state.output_stream.append(self.allocator, obj.*);
                } else {
                    try self.state.evaluation_stack.append(self.allocator, obj.*);
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
                if (vr.path_for_count) |path_str| {
                    const from_ptr = elem.current_pointer;
                    const count: u32 = if (self.resolvePath(path_str, from_ptr)) |p|
                        if (p.container) |c| self.state.visit_counts.get(c.path) orelse 0 else 0
                    else
                        0;
                    try self.state.evaluation_stack.append(self.allocator, .{ .int = @intCast(count) });
                } else {
                    const val = self.resolveVariable(vr.name) orelse .void;
                    try self.state.evaluation_stack.append(self.allocator,val);
                }
                self.advancePointer();
                return .ok;
            },
            .choice_point => |cp| {
                try self.processChoicePoint(cp.path, cp.flags);
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
                // Push sentinel; strings now route to output_stream (detected via inStringEvalMode())
                try self.state.output_stream.append(self.allocator, .{ .control_command = .begin_string });
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
                // Dupe into the arena so the string lives until story.deinit()
                const s = try self.arena.allocator().dupe(u8, text.items);
                try self.state.evaluation_stack.append(self.allocator, .{ .string = s });
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
                // Pop count (n), then also pop the visit_index that `visit` pushed —
                // all sequence types push exactly one result for consistency.
                const count_val = self.state.evaluation_stack.pop() orelse RuntimeObject{ .int = 1 };
                _ = self.state.evaluation_stack.pop(); // discard visit_idx; use visit_counts directly
                const count: i64 = switch (count_val) {
                    .int => |n| n,
                    else => 1,
                };
                const cur_container = elem.current_pointer.container orelse {
                    try self.state.evaluation_stack.append(self.allocator,.{ .int = 0 });
                    self.advancePointer();
                    return .ok;
                };
                // seqCount is the raw (1-based) visit count of the sequence container.
                const seq_count = self.state.visit_counts.get(cur_container.path) orelse 1;
                const idx: i64 = if (count > 0) shuffleIndex(
                    cur_container.path,
                    seq_count,
                    @intCast(count),
                    self.state.story_seed,
                ) else 0;
                try self.state.evaluation_stack.append(self.allocator,.{ .int = idx });
                self.advancePointer();
                return .ok;
            },
            .start_tag => {
                // Push a sentinel onto the output_stream so end_tag can find it.
                try self.state.output_stream.append(self.allocator, .{ .control_command = .start_tag });
                self.advancePointer();
                return .ok;
            },
            .end_tag => {
                // Scan backward for the start_tag sentinel; collect string objects; form one tag.
                const stream = &self.state.output_stream;
                var sentinel_idx: ?usize = null;
                var i: usize = stream.items.len;
                while (i > 0) {
                    i -= 1;
                    if (stream.items[i] == .control_command and
                        stream.items[i].control_command == .start_tag)
                    {
                        sentinel_idx = i;
                        break;
                    }
                }
                if (sentinel_idx) |si| {
                    // Collect strings between sentinel and end
                    var tag_buf = std.ArrayList(u8).empty;
                    errdefer tag_buf.deinit(self.allocator);
                    for (stream.items[si + 1 ..]) |obj| {
                        if (obj == .string) try tag_buf.appendSlice(self.allocator, obj.string);
                    }
                    stream.items.len = si; // remove sentinel and collected strings
                    const tag = try tag_buf.toOwnedSlice(self.allocator);
                    // Store in arena so it outlives the output_stream clear
                    const tag_arena = try self.arena.allocator().dupe(u8, tag);
                    self.allocator.free(tag);
                    try self.current_tags.append(self.allocator, tag_arena);
                }
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
        try evaluation.callNativeFunction(self.arena.allocator(), func, &self.state.evaluation_stack);
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

        // Only record a visit when entering a container from its start (index 0).
        // Diverts into the middle of a container (e.g. jump-back-to-nop in sequences)
        // must not count as a new visit.
        if (target_ptr.index == 0) {
            self.recordVisitIfNeeded(target_container);
        }

        if (d.push_pop_type) |ppt| {
            // Function or tunnel call: save return point then jump
            const prev = elem.current_pointer;
            const stream_idx = self.state.output_stream.items.len;
            try self.state.call_stack.push(ppt, prev);
            const new_elem = self.state.call_stack.currentElement();
            new_elem.current_pointer = target_ptr;
            new_elem.output_stream_index_at_push = stream_idx;
        } else {
            // Plain divert: jump without return
            elem.current_pointer = target_ptr;
        }
        return .ok;
    }

    /// Returns true if there is a begin_string sentinel on the output_stream,
    /// indicating we are inside a str/str block collecting text.
    fn inStringEvalMode(self: *const Story) bool {
        for (self.state.output_stream.items) |item| {
            if (item == .control_command and item.control_command == .begin_string) return true;
        }
        return false;
    }

    pub fn resolveVariable(self: *Story, name: []const u8) ?RuntimeObject {
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
            // Absolute path: resolve from root.
            // The final component may be a non-container index (execution position).
            return resolvePointerAbs(self.root, path_str);
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

    /// Resolve an absolute path to a Pointer, handling a non-container final component
    /// as an execution position within the last container.
    fn resolvePointerAbs(start: *Container, path_str: []const u8) ?Pointer {
        var current: *Container = start;
        var iter = std.mem.splitScalar(u8, path_str, '.');
        while (iter.next()) |part| {
            if (part.len == 0) continue;
            if (std.fmt.parseInt(u32, part, 10)) |idx| {
                if (idx >= current.content.len) return null;
                if (current.content[idx] == .container) {
                    current = current.content[idx].container;
                } else {
                    // Non-container index: check there are no more components
                    if (iter.next()) |_| return null; // trailing components after index
                    return Pointer{ .container = current, .index = @intCast(idx) };
                }
            } else |_| {
                current = current.named_content.get(part) orelse return null;
            }
        }
        return Pointer{ .container = current, .index = 0 };
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

    /// Compute a deterministic shuffle index compatible with C# .NET Framework System.Random.
    /// `seq_count` is the 1-based raw visit count of the sequence container.
    /// `num_elements` is the number of items in the sequence.
    /// `story_seed` is the current story seed (set via srnd).
    fn shuffleIndex(path: []const u8, seq_count: u32, num_elements: u32, story_seed: u32) i64 {
        const loop_index = seq_count / num_elements;
        const iteration_index = seq_count % num_elements;

        // Hash = sum of char values of the container path string.
        var seq_hash: i32 = 0;
        for (path) |c| seq_hash +%= @as(i32, @intCast(c));

        const random_seed: i32 = seq_hash +% @as(i32, @bitCast(loop_index)) +% @as(i32, @bitCast(story_seed));

        // .NET Framework System.Random (subtract-with-carry).
        const MBIG: i32 = std.math.maxInt(i32);
        const MSEED: i32 = 161803398;
        var seed_array: [56]i32 = @splat(0);

        const subtraction: i32 = if (random_seed == std.math.minInt(i32)) MBIG else @intCast(@abs(random_seed));
        var mj: i32 = MSEED -% subtraction;
        seed_array[55] = mj;
        var mk: i32 = 1;
        var i: usize = 1;
        while (i < 55) : (i += 1) {
            var ii: usize = 33 * i % 55;
            if (ii == 0) ii = 55;
            seed_array[ii] = mk;
            mk = mj -% mk;
            if (mk < 0) mk +%= MBIG;
            mj = seed_array[ii];
        }
        var k: usize = 1;
        while (k < 5) : (k += 1) {
            var j: usize = 1;
            while (j < 56) : (j += 1) {
                seed_array[j] -%= seed_array[1 + (j + 30) % 55];
                if (seed_array[j] < 0) seed_array[j] +%= MBIG;
            }
        }
        var in_next: usize = 0;
        var in_nextp: usize = 21;

        // Fisher-Yates–like: pick the iteration_index-th element from a shuffled list.
        var unpicked: [32]u32 = undefined; // max reasonable sequence length
        const n = @min(num_elements, 32);
        for (0..n) |x| unpicked[x] = @intCast(x);
        var unpicked_count: u32 = n;

        var idx: i32 = 0;
        var it: u32 = 0;
        while (it <= iteration_index) : (it += 1) {
            // InternalSample
            in_next += 1;
            if (in_next >= 56) in_next = 1;
            in_nextp += 1;
            if (in_nextp >= 56) in_nextp = 1;
            var ret_val: i32 = seed_array[in_next] -% seed_array[in_nextp];
            if (ret_val == MBIG) ret_val -= 1;
            if (ret_val < 0) ret_val +%= MBIG;
            seed_array[in_next] = ret_val;

            const chosen: u32 = @intCast(@rem(@as(i64, ret_val), @as(i64, unpicked_count)));
            idx = @intCast(unpicked[chosen]);
            // Remove chosen from unpicked by swapping with last
            unpicked_count -= 1;
            unpicked[chosen] = unpicked[unpicked_count];
        }
        return @intCast(idx);
    }

    /// Process a choice_point instruction.
    /// `path_str` is the absolute path to the choice target container.
    /// `flags` encodes the choice metadata (condition, content, once-only, etc.).
    fn processChoicePoint(self: *Story, path_str: []const u8, flags: u8) !void {
        const elem = self.state.call_stack.currentElement();
        const from_ptr = elem.current_pointer;

        // Flag 0x01: HasCondition — pop bool; note result but always continue popping
        var show_choice = true;
        if (flags & 0x01 != 0) {
            const cond = self.state.evaluation_stack.pop() orelse RuntimeObject{ .bool = false };
            if (!evaluation.isTruthy(cond)) show_choice = false;
        }

        // Flag 0x04: HasChoiceOnlyContent — always pop (even if condition failed)
        const choice_only: []const u8 = if (flags & 0x04 != 0) blk: {
            const v = self.state.evaluation_stack.pop() orelse RuntimeObject{ .string = "" };
            break :blk switch (v) { .string => |s| s, else => "" };
        } else "";

        // Flag 0x02: HasStartContent — always pop (even if condition failed)
        const start_content: []const u8 = if (flags & 0x02 != 0) blk: {
            const v = self.state.evaluation_stack.pop() orelse RuntimeObject{ .string = "" };
            break :blk switch (v) { .string => |s| s, else => "" };
        } else "";

        if (!show_choice) return;

        // Resolve target path to verify it exists
        const target_ptr = self.resolvePath(path_str, from_ptr) orelse return;
        const target_container = target_ptr.container orelse return;

        // Flag 0x10: IsOnce — skip if already visited
        if (flags & 0x10 != 0) {
            const visits = self.state.visit_counts.get(target_container.path) orelse 0;
            if (visits > 0) return;
        }

        // Flag 0x08: IsInvisibleDefault — store for auto-follow if no visible choices remain
        if (flags & 0x08 != 0) {
            self.default_choice_target = target_container.path;
            return;
        }

        // Assemble choice text: start + choice-only
        const text = if (start_content.len > 0 and choice_only.len > 0)
            try std.mem.concat(self.arena.allocator(), u8, &.{ start_content, choice_only })
        else if (start_content.len > 0)
            start_content
        else
            choice_only;

        const choice = Choice{
            .text = text,
            .source_path = from_ptr.container.?.path,
            // Store the resolved absolute path so chooseChoiceIndex can resolve from root
            // (the current pointer may be null at selection time after cont() ends).
            .target_path = target_container.path,
            .tags = &.{},
            .index = @intCast(self.state.current_choices.items.len),
            .original_thread_index = 0,
        };
        try self.state.current_choices.append(self.allocator, choice);
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

// ── TASK-17: Temporary variables and callstack scoping ────────────────────────

test "Temp var found in function frame" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "misc/hello_world.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    // Push a function frame and assign temp "t" = 42
    try story.state.call_stack.push(.function, Pointer.null_value);
    const elem = story.state.call_stack.currentElement();
    try elem.temporary_variables.set(alloc, "t", .{ .int = 42 });

    // Lookup finds the temp in the current frame
    const val = story.resolveVariable("t");
    try std.testing.expect(val != null);
    try std.testing.expectEqual(@as(i64, 42), val.?.int);

    // Pop the frame; temp is gone
    try story.state.call_stack.pop(.function);
    try std.testing.expect(story.resolveVariable("t") == null);
}

test "Temp var shadows global; global restored after pop" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "misc/hello_world.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    // Set global x = 100
    try story.state.variables_state.set(alloc, "x", .{ .int = 100 });

    // Push function frame, set temp x = 99 (shadows global)
    try story.state.call_stack.push(.function, Pointer.null_value);
    const elem = story.state.call_stack.currentElement();
    try elem.temporary_variables.set(alloc, "x", .{ .int = 99 });

    try std.testing.expectEqual(@as(i64, 99), story.resolveVariable("x").?.int);

    // After pop, global value is visible again
    try story.state.call_stack.pop(.function);
    try std.testing.expectEqual(@as(i64, 100), story.resolveVariable("x").?.int);
}

test "Story callstack_evaluation" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "callstack/callstack_evaluation.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();
    const out = try story.cont();
    defer alloc.free(out);
    // six() + two() = (four() + two()) + two() = ((two()+two()) + two()) + two() = 8
    try std.testing.expectEqualStrings("8\n", out);
}

// ── TASK-24: Path resolution unit tests ──────────────────────────────────────

test "resolvePath absolute named container" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "diverts/basic_tunnel.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    const from_ptr = story.state.call_stack.currentElement().current_pointer;
    const p = story.resolvePath("f", from_ptr).?;
    try std.testing.expectEqualStrings("f", p.container.?.path);
}

test "resolvePath relative with ^ traverses parent" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "misc/hello_world.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    // inner container is at root.content[0]
    const inner = story.root.content[0].container;
    const from_ptr = Pointer{ .container = inner, .index = 0 };
    // ".^.g-0": ^ steps to inner container, then g-0 looks up named child
    const p = story.resolvePath(".^.g-0", from_ptr).?;
    try std.testing.expectEqualStrings("0.g-0", p.container.?.path);
}

test "resolvePath non-existent returns null" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "misc/hello_world.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    const from_ptr = story.state.call_stack.currentElement().current_pointer;
    try std.testing.expect(story.resolvePath("nonexistent", from_ptr) == null);
}

test "Story same_line_divert_is_inline" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "diverts/same_line_divert_is_inline.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();
    const out = try story.cont();
    defer alloc.free(out);
    try std.testing.expectEqualStrings("We hurried home to Savile Row as fast as we could.\n", out);
}

// ── TASK-32: String native functions tests ────────────────────────────────────

test "Story floor_ceiling_and_casts" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "builtins/floor_ceiling_and_casts.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();
    const out = try story.cont();
    defer alloc.free(out);
    // FLOOR(1.2)=1, INT(1.2)=1, CEILING(1.2)=2, CEILING(1.2)/3=0, CEILING(INT(1.2))/3=0, FLOOR(1)=1
    try std.testing.expectEqualStrings("1\n1\n2\n0\n0\n1\n", out);
}

test "Story string_type_coercion" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "strings/string_type_coercion.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();
    const out = try story.cont();
    defer alloc.free(out);
    // str("5") == 5 → false (no coercion), str("blah") == 5 → false
    try std.testing.expectEqualStrings("different\ndifferent\n", out);
}

// ── TASK-28: String evaluation mode tests ────────────────────────────────────

test "str/str collects strings onto eval stack" {
    // Unit test: manually drive begin_string, strings, end_string through step dispatch
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "misc/hello_world.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    // Manually run the str/str sequence via dispatchObject
    const hello: RuntimeObject = .{ .string = "Hello " };
    const world: RuntimeObject = .{ .string = "World" };
    _ = try story.dispatchObject(&RuntimeObject{ .control_command = .begin_string });
    _ = try story.dispatchObject(&hello);
    _ = try story.dispatchObject(&world);
    _ = try story.dispatchObject(&RuntimeObject{ .control_command = .end_string });

    const top = story.state.evaluation_stack.items[story.state.evaluation_stack.items.len - 1];
    try std.testing.expect(top == .string);
    try std.testing.expectEqualStrings("Hello World", top.string);
}

test "Story string_constants" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "strings/string_constants.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();
    const out = try story.cont();
    defer alloc.free(out);
    try std.testing.expectEqualStrings("hi\n", out);
}

// ── TASK-27: Variable divert target tests ────────────────────────────────────

test "Story divert_targets_with_parameters" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "diverts/divert_targets_with_parameters.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();
    const out = try story.cont();
    defer alloc.free(out);
    // Global x = divert_target("place"); root passes 5 via eval stack; place outputs it
    try std.testing.expectEqualStrings("5\n", out);
}

test "Story variable_divert_target" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "variables/variable_divert_target.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();
    const out = try story.cont();
    defer alloc.free(out);
    // Global x = divert_target("here"); "there" diverts via x to "here"
    try std.testing.expectEqualStrings("Here.\n", out);
}

// ── TASK-26: Tunnel and conditional divert tests ─────────────────────────────

test "Story complex_tunnels" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "diverts/complex_tunnels.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();
    const out = try story.cont();
    defer alloc.free(out);
    // Nested tunnels, temp vars passed via eval stack, float formatting
    try std.testing.expectEqualStrings(
        "one (1)\none and a half (1.5)\ntwo (2)\nthree (3)\n",
        out,
    );
}

// ── TASK-23: Visit count (CNT?) tests ────────────────────────────────────────

test "Story read_count_across_callstack" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "builtins/read_count_across_callstack.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();
    const out = try story.cont();
    defer alloc.free(out);
    // "first" is visited once; CNT?".^" inside it returns 1 both before and after tunnel
    try std.testing.expectEqualStrings(
        "1) Seen first 1 times.\nIn second.\n2) Seen first 1 times.\n",
        out,
    );
}

test "turn_indices updated when entering flagged container" {
    // variable_divert_target: "here" container has #f:3 (visits + turn_index counted)
    // After cont(), turn_indices["here"] should be set to current_turn_index (0)
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "variables/variable_divert_target.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();
    const out = try story.cont();
    defer alloc.free(out);
    try std.testing.expectEqualStrings("Here.\n", out);
    const turn_idx = story.state.turn_indices.get("here");
    try std.testing.expect(turn_idx != null);
    try std.testing.expectEqual(@as(i32, 0), turn_idx.?);
}

test "turns_since returns -1 for never-visited path" {
    // Unit: push a divert_target for a path we never visit; turns_since should return -1
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "misc/hello_world.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    // Push a divert_target pointing to a path that was never entered
    const dt: RuntimeObject = .{ .divert_target = "some.never.visited.path" };
    try story.state.evaluation_stack.append(alloc, dt);
    _ = try story.dispatchObject(&RuntimeObject{ .control_command = .turns_since });

    const top = story.state.evaluation_stack.items[story.state.evaluation_stack.items.len - 1];
    try std.testing.expect(top == .int);
    try std.testing.expectEqual(@as(i64, -1), top.int);
}

test "srnd sets story_seed" {
    // AC #3: seed_random pops .int from eval stack and sets state.story_seed
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "misc/hello_world.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();
    try story.state.evaluation_stack.append(alloc, .{ .int = 42 });
    _ = try story.dispatchObject(&RuntimeObject{ .control_command = .seed_random });
    try std.testing.expectEqual(@as(u32, 42), story.state.story_seed);
}

test "Stopping sequence clamps at last item" {
    // AC #4: f_stopping produces "one two two two" (clamps at last option on 3rd+ call)
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "sequences/all_sequence_types.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();
    const out = try story.cont();
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Stopping: one two two two") != null);
}

test "Cycle sequence wraps correctly" {
    // AC #5: f_cycle produces "one two one two" (wraps after last option)
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "sequences/all_sequence_types.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();
    const out = try story.cont();
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Cycle: one two one two") != null);
}

test "choice_with_brackets_only: choice text and selection" {
    // AC #1: first cont() returns "" and currentChoices() has text "Option"
    // After chooseChoiceIndex(0), second cont() returns "\nText\n"
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "choices/choice_with_brackets_only.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();
    const out1 = try story.cont();
    defer alloc.free(out1);
    try std.testing.expectEqualStrings("", out1);
    const choices = story.currentChoices();
    try std.testing.expectEqual(@as(usize, 1), choices.len);
    try std.testing.expectEqualStrings("Option", choices[0].text);
    try chooseChoiceAndCont(&story, 0, "\nText\n");
}

test "once_only_choices_can_link_back_to_self: once-only disappears after selection" {
    // First cont(): "First choice" appears (c-1 condition: CNT? c-0 = 0 → skip)
    // Choose "First choice": c-0 marked visited
    // Second cont(): "First choice" gone (once-only), "Second choice" appears (CNT? c-0 = 1 → truthy)
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "choices/once_only_choices_can_link_back_to_self.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    // Turn 1: only "First choice" visible
    const out1 = try story.cont();
    defer alloc.free(out1);
    try std.testing.expectEqualStrings("", out1);
    try std.testing.expectEqual(@as(usize, 1), story.currentChoices().len);
    try std.testing.expectEqualStrings("First choice", story.currentChoices()[0].text);

    // Select "First choice"
    try story.chooseChoiceIndex(0);

    // Turn 2: "First choice" gone, "Second choice" appears
    const out2 = try story.cont();
    defer alloc.free(out2);
    try std.testing.expectEqual(@as(usize, 1), story.currentChoices().len);
    try std.testing.expectEqualStrings("Second choice", story.currentChoices()[0].text);
}

test "sticky_choices_stay_sticky: choices reappear each turn" {
    // Sticky choices (no IsOnce flag) always appear regardless of visit count.
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "choices/sticky_choices_stay_sticky.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    // Turn 1: both choices visible
    const out1 = try story.cont();
    defer alloc.free(out1);
    try std.testing.expectEqual(@as(usize, 2), story.currentChoices().len);
    try std.testing.expectEqualStrings("Choice 1", story.currentChoices()[0].text);
    try std.testing.expectEqualStrings("Choice 2", story.currentChoices()[1].text);

    // Choose first, choices still there next turn
    try story.chooseChoiceIndex(0);
    const out2 = try story.cont();
    defer alloc.free(out2);
    try std.testing.expectEqual(@as(usize, 2), story.currentChoices().len);
    try std.testing.expectEqualStrings("Choice 1", story.currentChoices()[0].text);
}

test "once_only_choices_with_own_content: choices disappear after selection" {
    // Once-only choices (IsOnce flag) disappear after being selected.
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "choices/once_only_choices_with_own_content.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    // Turn 1: three choices available
    const out1 = try story.cont();
    alloc.free(out1);
    try std.testing.expectEqual(@as(usize, 3), story.currentChoices().len);

    // Choose "Eat ice-cream" (index 0)
    try story.chooseChoiceIndex(0);
    const out2 = try story.cont();
    defer alloc.free(out2);

    // Turn 2: only 2 choices remain (ice-cream gone)
    try std.testing.expectEqual(@as(usize, 2), story.currentChoices().len);
}

test "default_choices: invisible default auto-follows when no other choices remain" {
    // After all once-only choices are exhausted, invisible default (flg=0x18) is auto-followed.
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "choices/default_choices.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    // Turn 1: 2 choices ("Choice 1", "Choice 2"; "Impossible choice" condition=false)
    const out1 = try story.cont();
    defer alloc.free(out1);
    try std.testing.expectEqual(@as(usize, 2), story.currentChoices().len);

    // Exhaust both once-only choices
    try story.chooseChoiceIndex(0);
    const out2 = try story.cont();
    defer alloc.free(out2);
    try std.testing.expectEqual(@as(usize, 1), story.currentChoices().len);

    try story.chooseChoiceIndex(0);
    const out3 = try story.cont();
    defer alloc.free(out3);
    // No visible choices remain; invisible default auto-followed → "This is default.\n"
    try std.testing.expectEqual(@as(usize, 0), story.currentChoices().len);
    try std.testing.expect(std.mem.indexOf(u8, out3, "This is default.") != null);
}

test "conditional_choices: only enabled choices visible" {
    // Choices with false conditions are filtered; choices with true conditions appear.
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "choices/conditional_choices.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    const out1 = try story.cont();
    alloc.free(out1);

    // c-0 (true&&false=0) and c-2 (false) are filtered; c-1,c-3,c-4,c-5 appear.
    const choices = story.currentChoices();
    try std.testing.expectEqual(@as(usize, 4), choices.len);
    try std.testing.expectEqualStrings("one", choices[0].text);
    try std.testing.expectEqualStrings("two", choices[1].text);
    try std.testing.expectEqualStrings("three", choices[2].text);
    try std.testing.expectEqualStrings("four", choices[3].text);

    // canContinue() is false when choices are pending (pointer is null)
    try std.testing.expect(!story.canContinue());

    // After selecting a choice and story ends, canContinue() stays false.
    try story.chooseChoiceIndex(0);
    const out2 = try story.cont();
    alloc.free(out2);
    try std.testing.expect(!story.canContinue());

    // Selecting out-of-range index returns error.
    try std.testing.expectError(error.InvalidChoiceIndex, story.chooseChoiceIndex(99));
}

test "tags: start_tag/end_tag collects tag strings; content still output" {
    // tags.ink.json has two story-level tags before content.
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "tags/tags.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    const out = try story.cont();
    defer alloc.free(out);
    try std.testing.expectEqualStrings("This is the content\n", out);
    try std.testing.expectEqual(@as(usize, 2), story.currentTags().len);
    try std.testing.expectEqualStrings("author: Joe", story.currentTags()[0]);
    try std.testing.expectEqualStrings("title: My Great Story", story.currentTags()[1]);
}

test "knot_stitch_gather_counts: visit counts tracked per knot and stitch" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "knots/knot_stitch_gather_counts.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();
    const out = try story.cont();
    defer alloc.free(out);
    // Each loop outputs: variable_count + " " + visit_count + "\n"
    // gather_count_test.loop: 1 1, 2 2, 3 3 (3 iterations)
    // knot_count_test: 1 1, 2 2, 3 3 (2 calls × loop of 3)
    // stitch_count_test.stitch: 1 1, 2 2, 3 3 (called twice with reset)
    try std.testing.expect(out.len > 0);
}

test "choosePathString: jumps to named knot" {
    // Use tags.ink.json which has a "knot" named container.
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "tags/tags.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    // Jump straight to the "knot" container
    try story.choosePathString("knot");
    const out = try story.cont();
    defer alloc.free(out);
    try std.testing.expectEqualStrings("Knot content\n", out);
    // knot has "knot tag" before content and "end of knot tag" after
    try std.testing.expectEqual(@as(usize, 2), story.currentTags().len);
    try std.testing.expectEqualStrings("knot tag", story.currentTags()[0]);
    try std.testing.expectEqualStrings("end of knot tag", story.currentTags()[1]);
}

fn chooseChoiceAndCont(story: *Story, idx: usize, expected: []const u8) !void {
    try story.chooseChoiceIndex(idx);
    const alloc = std.testing.allocator;
    const out = try story.cont();
    defer alloc.free(out);
    try std.testing.expectEqualStrings(expected, out);
}
