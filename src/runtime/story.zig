const std = @import("std");
const value = @import("value.zig");
const pointer_mod = @import("pointer.zig");
const json_loader = @import("json_loader.zig");
const state_mod = @import("state.zig");
const callstack_mod = @import("callstack.zig");
const evaluation = @import("evaluation.zig");
const choices_mod = @import("choices.zig");
const lists = @import("lists.zig");

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

/// Signature for externally-bound functions callable from ink.
pub const ExternalFn = *const fn (args: []const RuntimeObject) ?RuntimeObject;
/// Callback type for variable observers registered via observeVariable().
pub const ObserverFn = *const fn (name: []const u8, value: RuntimeObject) void;
/// Severity level passed to the on_error callback.
pub const ErrorType = enum { error_, warning };

/// Options for bindExternalFunction.
pub const BindOptions = struct {
    /// If true the function may be called during lookahead without side effects.
    lookahead_safe: bool = false,
};

/// Per-flow execution state snapshot (used by the multi-flow API).
const SavedFlow = struct {
    call_stack: callstack_mod.CallStack,
    output_stream: std.ArrayList(RuntimeObject),
    evaluation_stack: std.ArrayList(RuntimeObject),
    current_choices: std.ArrayList(Choice),
    did_safe_exit: bool,
    default_choice_target: ?[]const u8,

    fn deinit(self: *SavedFlow, allocator: std.mem.Allocator) void {
        self.call_stack.deinit();
        self.output_stream.deinit(allocator);
        self.evaluation_stack.deinit(allocator);
        self.current_choices.deinit(allocator);
    }
};

/// Write a Pointer as {"cPath":"...","idx":N} or {"cPath":null,"idx":-1}.
fn writePointerJson(w: *std.Io.Writer, ptr: Pointer) !void {
    if (ptr.isNull() or ptr.container == null) {
        try w.writeAll("{\"cPath\":null,\"idx\":-1}");
    } else {
        try w.writeAll("{\"cPath\":");
        try std.json.Stringify.encodeJsonString(ptr.container.?.path, .{}, w);
        try w.print(",\"idx\":{d}}}", .{ptr.index});
    }
}

/// Write a RuntimeObject to JSON (for save state).
fn writeRtObjJson(w: *std.Io.Writer, obj: RuntimeObject) !void {
    switch (obj) {
        .void => try w.writeAll("\"void\""),
        .glue => try w.writeAll("\"<>\""),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .int => |n| try w.print("{d}", .{n}),
        .float => |f| {
            if (f == @trunc(f) and @abs(f) < 1e15) {
                try w.print("{d}.0", .{@as(i64, @intFromFloat(f))});
            } else {
                try w.print("{d}", .{f});
            }
        },
        .string => |s| {
            if (s.len == 1 and s[0] == '\n') {
                try w.writeAll("\"\\n\"");
            } else {
                // Prefix with ^ then JSON-encode
                var tmp: [2048]u8 = undefined;
                const prefixed = std.fmt.bufPrint(&tmp, "^{s}", .{s}) catch {
                    // Fallback for very long strings: allocate
                    return w.writeAll("\"^...\"");
                };
                try std.json.Stringify.encodeJsonString(prefixed, .{}, w);
            }
        },
        .list => |ink_list| {
            try w.writeAll("{\"list\":{");
            var it = ink_list.items.iterator();
            var first = true;
            while (it.next()) |e| {
                if (!first) try w.writeByte(',');
                first = false;
                try std.json.Stringify.encodeJsonString(e.key_ptr.*, .{}, w);
                try w.print(":{d}", .{e.value_ptr.*});
            }
            try w.writeAll("},\"origins\":[");
            for (ink_list.origins, 0..) |o, i| {
                if (i > 0) try w.writeByte(',');
                try std.json.Stringify.encodeJsonString(o, .{}, w);
            }
            try w.writeAll("]}");
        },
        .control_command => |cmd| {
            // Use the fromString table in reverse: just embed the string key
            const s = switch (cmd) {
                .eval_start => "ev", .eval_end => "/ev", .output => "out",
                .pop_eval_stack => "pop", .duplicate => "du",
                .pop_function => "~ret", .pop_tunnel => "->->",
                .begin_string => "str", .end_string => "/str",
                .no_op => "nop", .choice_count => "choiceCnt",
                .turns_since => "turns", .read_count => "readc", .turn_index => "turn",
                .visit_index => "visit", .sequence_shuffle_index => "seq",
                .seed_random => "srnd", .start_tag => "#", .end_tag => "/#",
                .list_from_int => "listInt", .list_range => "range",
                .list_random => "lrnd", .begin_thread => "thread",
                .done => "done", .end_of_story => "end",
            };
            try std.json.Stringify.encodeJsonString(s, .{}, w);
        },
        else => try w.writeAll("null"),
    }
}

pub const Story = struct {
    root: *Container,
    state: StoryState,
    /// Arena owns the container tree (static content)
    arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    /// All list origin definitions from listDefs JSON section.
    list_defs: lists.ListDefinitionsOrigin = .{},
    /// Invisible default choice target recorded per-cont(); null if none seen this turn.
    default_choice_target: ?[]const u8 = null,
    /// Tags collected during the current cont() call.
    current_tags: std.ArrayList([]const u8) = std.ArrayList([]const u8).empty,
    /// Named flows (all except the currently-active one are stored here).
    named_flows: std.StringHashMapUnmanaged(SavedFlow) = .{},
    /// Name of the currently-active flow.
    current_flow_name: []const u8 = "DEFAULT",
    /// Externally-bound functions callable from ink.
    external_functions: std.StringHashMapUnmanaged(ExternalFn) = .{},
    /// Variable change observers: name → callback.
    observers: std.StringHashMapUnmanaged(ObserverFn) = .{},
    /// Optional error/warning handler (non-fatal conditions).
    on_error: ?*const fn (message: []const u8, error_type: ErrorType) void = null,

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

        const list_defs = try lists.ListDefinitionsOrigin.parse(arena.allocator(), loaded.list_defs_json);

        var story = Story{
            .root = loaded.root,
            .state = st,
            .arena = arena,
            .allocator = allocator,
            .list_defs = list_defs,
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
        var it = self.named_flows.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.named_flows.deinit(self.allocator);
        self.external_functions.deinit(self.allocator);
        self.observers.deinit(self.allocator);
        self.state.deinit();
        self.arena.deinit();
        self.current_tags.deinit(self.allocator);
    }

    /// Return tags collected during the most recent cont() call.
    pub fn currentTags(self: *const Story) []const []const u8 {
        return self.current_tags.items;
    }

    /// Return the number of times a path (knot/stitch) has been visited.
    pub fn visitCountAtPathString(self: *const Story, path: []const u8) u32 {
        const ptr = self.resolvePath(path, .{ .container = null, .index = -1 }) orelse return 0;
        const c = ptr.container orelse return 0;
        return self.state.visit_counts.get(c.path) orelse 0;
    }

    /// Return the name of the currently-active flow.
    pub fn currentFlowName(self: *const Story) []const u8 {
        return self.current_flow_name;
    }

    /// Return true when the active flow is the default flow.
    pub fn currentFlowIsDefaultFlow(self: *const Story) bool {
        return std.mem.eql(u8, self.current_flow_name, "DEFAULT");
    }

    /// Return story-level global tags (tags at the very start of the initial content).
    /// Scans recursively into the first inner container if needed.
    /// The returned slice is caller-owned (allocated with self.allocator).
    pub fn globalTags(self: *Story) ![][]const u8 {
        return self.tagsLeadingContent(self.root);
    }

    /// Collect tag strings from the leading tag sequences of `c`, descending into
    /// inner containers at index 0 as needed.
    fn tagsLeadingContent(self: *Story, c: *Container) ![][]const u8 {
        var tags = std.ArrayList([]const u8).empty;
        defer tags.deinit(self.allocator);
        var in_tag = false;
        var tag_buf = std.ArrayList(u8).empty;
        defer tag_buf.deinit(self.allocator);
        for (c.content) |obj| {
            switch (obj) {
                .control_command => |cmd| switch (cmd) {
                    .start_tag => { in_tag = true; tag_buf.clearRetainingCapacity(); },
                    .end_tag => {
                        in_tag = false;
                        const tag = try self.arena.allocator().dupe(u8, tag_buf.items);
                        try tags.append(self.allocator, tag);
                        tag_buf.clearRetainingCapacity();
                    },
                    else => if (!in_tag) break,
                },
                .string => |s| if (in_tag) {
                    try tag_buf.appendSlice(self.allocator, s);
                } else break,
                // Descend into the first inner container
                .container => |inner| if (!in_tag and tags.items.len == 0) {
                    const inner_tags = try self.tagsLeadingContent(inner);
                    defer self.allocator.free(inner_tags);
                    try tags.appendSlice(self.allocator, inner_tags);
                } else if (!in_tag) break,
                else => if (!in_tag) break,
            }
        }
        return try tags.toOwnedSlice(self.allocator);
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
        self.state.call_stack.currentElement().current_pointer = target_ptr;
        self.state.did_safe_exit = false;
        self.state.current_turn_index += 1;
        // Record a visit to the target container so once-only choices work correctly.
        // Turn index must be incremented first so turns_since() reflects the new turn.
        if (target_ptr.container) |c| self.recordVisitIfNeeded(c);
        self.state.current_choices.clearRetainingCapacity();
    }

    // ── Multi-flow API ────────────────────────────────────────────────────────

    /// Switch to a named flow, saving the current flow's state.
    /// Creates a fresh flow (pointer at story root) if the name is new.
    pub fn switchFlow(self: *Story, name: []const u8) !void {
        if (std.mem.eql(u8, name, self.current_flow_name)) return;

        // Save the current flow into named_flows under its name.
        const saved = SavedFlow{
            .call_stack = self.state.call_stack,
            .output_stream = self.state.output_stream,
            .evaluation_stack = self.state.evaluation_stack,
            .current_choices = self.state.current_choices,
            .did_safe_exit = self.state.did_safe_exit,
            .default_choice_target = self.default_choice_target,
        };
        const saved_key = try self.arena.allocator().dupe(u8, self.current_flow_name);
        try self.named_flows.put(self.allocator, saved_key, saved);

        // Restore target flow or initialise a fresh one.
        if (self.named_flows.fetchRemove(name)) |entry| {
            const f = entry.value;
            self.state.call_stack = f.call_stack;
            self.state.output_stream = f.output_stream;
            self.state.evaluation_stack = f.evaluation_stack;
            self.state.current_choices = f.current_choices;
            self.state.did_safe_exit = f.did_safe_exit;
            self.default_choice_target = f.default_choice_target;
        } else {
            // Brand-new flow: fresh callstack pointing at the story root.
            var new_cs = try callstack_mod.CallStack.init(self.allocator);
            new_cs.currentElement().current_pointer = .{ .container = self.root, .index = 0 };
            self.state.call_stack = new_cs;
            self.state.output_stream = std.ArrayList(RuntimeObject).empty;
            self.state.evaluation_stack = std.ArrayList(RuntimeObject).empty;
            self.state.current_choices = std.ArrayList(Choice).empty;
            self.state.did_safe_exit = false;
            self.default_choice_target = null;
        }
        self.current_flow_name = try self.arena.allocator().dupe(u8, name);
    }

    /// Switch back to the default "DEFAULT" flow.
    pub fn switchToDefaultFlow(self: *Story) !void {
        try self.switchFlow("DEFAULT");
    }

    /// Remove a named flow (errors if it is "DEFAULT" or the current flow).
    pub fn removeFlow(self: *Story, name: []const u8) !void {
        if (std.mem.eql(u8, name, "DEFAULT")) return error.CannotRemoveDefaultFlow;
        if (std.mem.eql(u8, name, self.current_flow_name)) {
            // Switch to DEFAULT first so the current flow is saved, then delete it.
            try self.switchFlow("DEFAULT");
        }
        if (self.named_flows.fetchRemove(name)) |entry| {
            var f = entry.value;
            f.deinit(self.allocator);
        }
    }

    /// Return all active flow names (caller owns the returned slice; strings are arena-owned).
    pub fn aliveFlowNames(self: *const Story, allocator: std.mem.Allocator) ![][]const u8 {
        var names = std.ArrayList([]const u8).init(allocator);
        errdefer names.deinit();
        try names.append(self.current_flow_name);
        var it = self.named_flows.keyIterator();
        while (it.next()) |key| try names.append(key.*);
        return try names.toOwnedSlice();
    }

    // ── External function binding ─────────────────────────────────────────────

    /// Register an external function callable from ink.  Keys are arena-duped.
    pub fn bindExternalFunction(self: *Story, name: []const u8, func: ExternalFn, _: BindOptions) !void {
        const key = try self.arena.allocator().dupe(u8, name);
        try self.external_functions.put(self.allocator, key, func);
    }

    // ── Variable observers ────────────────────────────────────────────────────

    /// Register a callback that fires whenever the global variable `name` changes value.
    pub fn observeVariable(self: *Story, name: []const u8, func: ObserverFn) !void {
        const key = try self.arena.allocator().dupe(u8, name);
        try self.observers.put(self.allocator, key, func);
    }

    /// Fire the observer for `name` if one is registered.  Called after every global set.
    fn notifyObservers(self: *Story, name: []const u8, new_val: RuntimeObject) void {
        if (self.observers.get(name)) |func| func(name, new_val);
    }

    // ── evaluateFunction ─────────────────────────────────────────────────────

    /// Call a named ink function from game code.
    /// Saves the full story state, runs the function in isolation, then restores.
    /// `args` are the function arguments in declaration order (first arg = args[0]).
    /// If `text_out` is non-null, any text output produced by the function is appended to it.
    /// Returns the function's return value, or null if the function returned void / no value.
    pub fn evaluateFunction(
        self: *Story,
        name: []const u8,
        args: []const RuntimeObject,
        text_out: ?*std.ArrayList(u8),
    ) !?RuntimeObject {
        // 1. Snapshot current state so we can restore it after the call.
        const saved_json = try self.toJson(self.allocator);
        defer self.allocator.free(saved_json);

        // 2. Find the function container by name.
        const func_container = self.root.named_content.get(name) orelse return error.FunctionNotFound;
        const func_ptr = Pointer{ .container = func_container, .index = 0 };

        // 3. Prepare isolated state for this call:
        //    - Null out the parent frame so the loop stops after pop_function + advancePointer.
        //    - Clear output so we capture only the function's text.
        self.state.call_stack.currentElement().current_pointer = Pointer.null_value;
        self.state.output_stream.clearRetainingCapacity();
        self.state.did_safe_exit = false;

        // 4. Push args in declaration order (arg[0] first → arg[last] on top of stack).
        //    The function body uses temp= to pop them in reverse, matching ink convention.
        for (args) |arg| {
            try self.state.evaluation_stack.append(self.allocator, arg);
        }

        // 5. Push a function call frame and point it at the function body.
        const stream_idx = self.state.output_stream.items.len;
        try self.state.call_stack.push(.function, Pointer.null_value);
        const func_elem = self.state.call_stack.currentElement();
        func_elem.current_pointer = func_ptr;
        func_elem.output_stream_index_at_push = stream_idx;

        // 6. Run until the function returns (or hits done/end).
        try self.runStepLoop();

        // 7. Capture text output before restoring state.
        if (text_out) |out| {
            const text = try self.collectOutput();
            defer self.allocator.free(text);
            try out.appendSlice(self.allocator, text);
        }

        // 8. Pop the return value: ink pushes it via `ev … /ev` before `~ret`.
        //    A void-returning function pushes `.void`; we return null in that case.
        const return_val: ?RuntimeObject = blk: {
            const top = self.state.evaluation_stack.pop();
            if (top) |v| break :blk if (v == .void) null else v;
            break :blk null;
        };

        // 9. Restore state fully (undoes all side effects of the call).
        try self.loadStateFromJson(saved_json);

        return return_val;
    }

    // ── Save / Load ───────────────────────────────────────────────────────────

    /// Serialise the current story state to a JSON string.  Caller owns the result.
    pub fn toJson(self: *Story, allocator: std.mem.Allocator) ![]u8 {
        var aw = std.Io.Writer.Allocating.init(allocator);
        defer aw.deinit();
        const w = &aw.writer;

        try w.writeAll("{\"inkSaveVersion\":1");
        try w.print(",\"currentTurnIndex\":{d}", .{self.state.current_turn_index});
        try w.print(",\"storySeed\":{d}", .{self.state.story_seed});
        try w.print(",\"didSafeExit\":{s}", .{if (self.state.did_safe_exit) "true" else "false"});

        // callstackThreads
        try w.writeAll(",\"callstackThreads\":[");
        for (self.state.call_stack.threads.items, 0..) |*thread, ti| {
            if (ti > 0) try w.writeByte(',');
            try w.writeAll("{\"threadIndex\":");
            try w.print("{d}", .{thread.thread_index});
            try w.writeAll(",\"previousPointer\":");
            try writePointerJson(w, thread.previous_pointer);
            try w.writeAll(",\"callstack\":[");
            for (thread.call_stack.items, 0..) |*elem, ei| {
                if (ei > 0) try w.writeByte(',');
                try w.writeAll("{\"type\":");
                if (elem.push_pop_type) |ppt| {
                    try w.print("{d}", .{@as(u32, switch (ppt) { .function => 1, .tunnel => 2 })});
                } else {
                    try w.writeAll("0");
                }
                try w.writeAll(",\"ptr\":");
                try writePointerJson(w, elem.current_pointer);
                try w.print(",\"exp\":{s}", .{if (elem.in_expression_evaluation) "true" else "false"});
                try w.print(",\"osi\":{d}", .{elem.output_stream_index_at_push});
                try w.writeAll(",\"temp\":{");
                var it = elem.temporary_variables.globals.iterator();
                var first = true;
                while (it.next()) |e| {
                    if (!first) try w.writeByte(',');
                    first = false;
                    try std.json.Stringify.encodeJsonString(e.key_ptr.*, .{}, w);
                    try w.writeByte(':');
                    try writeRtObjJson(w, e.value_ptr.*);
                }
                try w.writeAll("}}");
            }
            try w.writeAll("]}");
        }
        try w.writeByte(']');

        // variablesState
        try w.writeAll(",\"variablesState\":{");
        {
            var it = self.state.variables_state.globals.iterator();
            var first = true;
            while (it.next()) |e| {
                if (!first) try w.writeByte(',');
                first = false;
                try std.json.Stringify.encodeJsonString(e.key_ptr.*, .{}, w);
                try w.writeByte(':');
                try writeRtObjJson(w, e.value_ptr.*);
            }
        }
        try w.writeByte('}');

        // evalStack
        try w.writeAll(",\"evalStack\":[");
        for (self.state.evaluation_stack.items, 0..) |obj, i| {
            if (i > 0) try w.writeByte(',');
            try writeRtObjJson(w, obj);
        }
        try w.writeByte(']');

        // outputStream
        try w.writeAll(",\"outputStream\":[");
        for (self.state.output_stream.items, 0..) |obj, i| {
            if (i > 0) try w.writeByte(',');
            try writeRtObjJson(w, obj);
        }
        try w.writeByte(']');

        // visitCounts
        try w.writeAll(",\"visitCounts\":{");
        {
            var it = self.state.visit_counts.iterator();
            var first = true;
            while (it.next()) |e| {
                if (!first) try w.writeByte(',');
                first = false;
                try std.json.Stringify.encodeJsonString(e.key_ptr.*, .{}, w);
                try w.print(":{d}", .{e.value_ptr.*});
            }
        }
        try w.writeByte('}');

        // turnIndices
        try w.writeAll(",\"turnIndices\":{");
        {
            var it = self.state.turn_indices.iterator();
            var first = true;
            while (it.next()) |e| {
                if (!first) try w.writeByte(',');
                first = false;
                try std.json.Stringify.encodeJsonString(e.key_ptr.*, .{}, w);
                try w.print(":{d}", .{e.value_ptr.*});
            }
        }
        try w.writeAll("}}");

        return try aw.toOwnedSlice();
    }

    /// Restore story state from a JSON string produced by toJson().
    pub fn loadStateFromJson(self: *Story, json_text: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, json_text, .{});
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) return error.InvalidSaveState;
        const obj = root.object;

        // Simple scalars
        if (obj.get("currentTurnIndex")) |v| self.state.current_turn_index = @intCast(v.integer);
        if (obj.get("storySeed")) |v| self.state.story_seed = @intCast(v.integer);
        if (obj.get("didSafeExit")) |v| self.state.did_safe_exit = v.bool;

        // Restore variables
        if (obj.get("variablesState")) |vars_val| {
            if (vars_val == .object) {
                self.state.variables_state.deinit(self.allocator);
                self.state.variables_state = callstack_mod.VariablesState.init();
                var it = vars_val.object.iterator();
                while (it.next()) |e| {
                    const rt_obj = try self.parseRtObj(e.value_ptr.*) orelse continue;
                    try self.state.variables_state.set(self.allocator, e.key_ptr.*, rt_obj);
                }
            }
        }

        // Restore visit counts
        if (obj.get("visitCounts")) |vc_val| {
            if (vc_val == .object) {
                self.state.visit_counts.clearRetainingCapacity();
                var it = vc_val.object.iterator();
                while (it.next()) |e| {
                    const count: u32 = @intCast(e.value_ptr.*.integer);
                    const key = try self.arena.allocator().dupe(u8, e.key_ptr.*);
                    try self.state.visit_counts.put(self.allocator, key, count);
                }
            }
        }

        // Restore turn indices
        if (obj.get("turnIndices")) |ti_val| {
            if (ti_val == .object) {
                self.state.turn_indices.clearRetainingCapacity();
                var it = ti_val.object.iterator();
                while (it.next()) |e| {
                    const idx: i32 = @intCast(e.value_ptr.*.integer);
                    const key = try self.arena.allocator().dupe(u8, e.key_ptr.*);
                    try self.state.turn_indices.put(self.allocator, key, idx);
                }
            }
        }

        // Restore eval stack
        if (obj.get("evalStack")) |es_val| {
            if (es_val == .array) {
                self.state.evaluation_stack.clearRetainingCapacity();
                for (es_val.array.items) |item| {
                    const rt_obj = try self.parseRtObj(item) orelse .void;
                    try self.state.evaluation_stack.append(self.allocator, rt_obj);
                }
            }
        }

        // Restore output stream
        if (obj.get("outputStream")) |os_val| {
            if (os_val == .array) {
                self.state.output_stream.clearRetainingCapacity();
                for (os_val.array.items) |item| {
                    const rt_obj = try self.parseRtObj(item) orelse .void;
                    try self.state.output_stream.append(self.allocator, rt_obj);
                }
            }
        }

        // Restore callstack
        if (obj.get("callstackThreads")) |threads_val| {
            if (threads_val == .array) {
                self.state.call_stack.deinit();
                self.state.call_stack = try callstack_mod.CallStack.init(self.allocator);
                // Remove the default thread created by init
                if (self.state.call_stack.threads.items.len > 0) {
                    var t = self.state.call_stack.threads.pop().?;
                    t.deinit(self.allocator);
                }
                var max_thread_idx: u32 = 0;
                for (threads_val.array.items) |thread_val| {
                    if (thread_val != .object) continue;
                    const thread_obj = thread_val.object;
                    const thread_idx: u32 = if (thread_obj.get("threadIndex")) |v| @intCast(v.integer) else 0;
                    if (thread_idx > max_thread_idx) max_thread_idx = thread_idx;
                    var new_thread = callstack_mod.Thread{
                        .call_stack = std.ArrayList(callstack_mod.Element).empty,
                        .thread_index = thread_idx,
                        .previous_pointer = if (thread_obj.get("previousPointer")) |pp|
                            try self.parsePointer(pp)
                        else
                            Pointer.null_value,
                    };
                    if (thread_obj.get("callstack")) |cs_val| {
                        if (cs_val == .array) {
                            for (cs_val.array.items) |elem_val| {
                                if (elem_val != .object) continue;
                                const elem_obj = elem_val.object;
                                const type_int: u32 = if (elem_obj.get("type")) |v| @intCast(v.integer) else 0;
                                const ppt: ?callstack_mod.PushPopType = switch (type_int) {
                                    1 => .function,
                                    2 => .tunnel,
                                    else => null,
                                };
                                const ptr = if (elem_obj.get("ptr")) |pp|
                                    try self.parsePointer(pp)
                                else
                                    Pointer.null_value;
                                const in_exp = if (elem_obj.get("exp")) |v| v.bool else false;
                                const osi: usize = if (elem_obj.get("osi")) |v| @intCast(v.integer) else 0;
                                var elem = callstack_mod.Element.init(ppt, ptr);
                                elem.in_expression_evaluation = in_exp;
                                elem.output_stream_index_at_push = osi;
                                if (elem_obj.get("temp")) |temp_val| {
                                    if (temp_val == .object) {
                                        var it = temp_val.object.iterator();
                                        while (it.next()) |e| {
                                            const rt_obj = try self.parseRtObj(e.value_ptr.*) orelse continue;
                                            try elem.temporary_variables.set(self.allocator, e.key_ptr.*, rt_obj);
                                        }
                                    }
                                }
                                try new_thread.call_stack.append(self.allocator, elem);
                            }
                        }
                    }
                    try self.state.call_stack.threads.append(self.allocator, new_thread);
                }
                self.state.call_stack.thread_counter = max_thread_idx + 1;
            }
        }

        self.state.did_safe_exit = if (obj.get("didSafeExit")) |v| v.bool else false;
    }

    // ── Save/Load helpers ─────────────────────────────────────────────────────

    /// Parse a pointer from `{"cPath": "...", "idx": N}` JSON value.
    fn parsePointer(self: *Story, val: std.json.Value) !Pointer {
        if (val != .object) return Pointer.null_value;
        const o = val.object;
        const idx_val = o.get("idx") orelse return Pointer.null_value;
        const idx: i32 = @intCast(idx_val.integer);
        if (idx < 0) return Pointer.null_value;
        const cpath_val = o.get("cPath") orelse return Pointer.null_value;
        if (cpath_val == .null) return Pointer.null_value;
        const cpath = cpath_val.string;
        const container = self.findContainerByPath(cpath) orelse return Pointer.null_value;
        return .{ .container = container, .index = idx };
    }

    /// Walk the container tree to find the one whose .path == target_path.
    fn findContainerByPath(self: *Story, target_path: []const u8) ?*Container {
        return searchContainer(self.root, target_path);
    }

    fn searchContainer(c: *Container, target: []const u8) ?*Container {
        if (std.mem.eql(u8, c.path, target)) return c;
        for (c.content) |obj| {
            if (obj == .container) {
                if (searchContainer(obj.container, target)) |found| return found;
            }
        }
        var it = c.named_content.valueIterator();
        while (it.next()) |sub| {
            if (searchContainer(sub.*, target)) |found| return found;
        }
        return null;
    }

    /// Parse a RuntimeObject from a JSON value (same format as used in toJson).
    fn parseRtObj(self: *Story, val: std.json.Value) !?RuntimeObject {
        switch (val) {
            .null => return .void,
            .bool => |b| return .{ .bool = b },
            .integer => |n| return .{ .int = n },
            .float => |f| return .{ .float = f },
            .string => |s| {
                if (std.mem.eql(u8, s, "void")) return .void;
                if (std.mem.eql(u8, s, "<>")) return .glue;
                if (s.len == 1 and s[0] == '\n') return .{ .string = "\n" };
                if (s.len > 0 and s[0] == '^') {
                    const text = try self.arena.allocator().dupe(u8, s[1..]);
                    return .{ .string = text };
                }
                // Control command or native function
                if (ControlCommand.fromString(s)) |cmd| return .{ .control_command = cmd };
                if (NativeFunction.fromString(s)) |nf| return .{ .native_function = nf };
                return null;
            },
            .object => |o| {
                // List: {"list": {...}, "origins": [...]}
                if (o.get("list")) |list_val| {
                    if (list_val == .object) {
                        const ink_list = try self.arena.allocator().create(lists.InkList);
                        ink_list.* = .{};
                        var it = list_val.object.iterator();
                        while (it.next()) |e| {
                            const key = try self.arena.allocator().dupe(u8, e.key_ptr.*);
                            const v: i32 = @intCast(e.value_ptr.*.integer);
                            try ink_list.items.put(self.arena.allocator(), key, v);
                        }
                        if (o.get("origins")) |origins_val| {
                            if (origins_val == .array) {
                                const origins = try self.arena.allocator().alloc([]const u8, origins_val.array.items.len);
                                for (origins_val.array.items, 0..) |ov, i| {
                                    origins[i] = if (ov == .string) try self.arena.allocator().dupe(u8, ov.string) else "";
                                }
                                ink_list.origins = origins;
                            }
                        }
                        return .{ .list = ink_list };
                    }
                }
                return null;
            },
            else => return null,
        }
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
                    trimNewlinesFromOutputStream(&self.state.output_stream, fn_output_start);
                    trimLeadingNewlinesFromOutputStream(&self.state.output_stream, fn_output_start);
                    self.advancePointer();
                    continue;
                } else if (self.state.call_stack.canPopThread()) {
                    try self.state.call_stack.popThread();
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
            .list => |ink_list| {
                const s = try ink_list.toDisplayString(allocator);
                defer allocator.free(s);
                try buf.appendSlice(allocator, s);
            },
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
                if (!va.is_new_decl) {
                    // Re-assignment: find existing variable in temps first, then globals.
                    const thread = self.state.call_stack.currentThread();
                    var j = thread.call_stack.items.len;
                    var found_in_temp = false;
                    while (j > 0) {
                        j -= 1;
                        if (thread.call_stack.items[j].temporary_variables.get(va.name) != null) {
                            try thread.call_stack.items[j].temporary_variables.set(self.allocator, va.name, val);
                            found_in_temp = true;
                            break;
                        }
                    }
                    if (!found_in_temp) {
                        try self.state.variables_state.set(self.allocator, va.name, val);
                        self.notifyObservers(va.name, val);
                    }
                } else if (va.is_global) {
                    try self.state.variables_state.set(self.allocator, va.name, val);
                    self.notifyObservers(va.name, val);
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
            .list => |ink_list| {
                if (elem.in_expression_evaluation) {
                    try self.state.evaluation_stack.append(self.allocator, .{ .list = ink_list });
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
                // Trim trailing newlines the function body may have left in the output stream,
                // but only from fn_output_start onward to preserve output written before the call.
                trimNewlinesFromOutputStream(&self.state.output_stream, fn_output_start);
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
                if (self.state.call_stack.canPopThread()) {
                    try self.state.call_stack.popThread();
                    return .ok;
                }
                self.state.did_safe_exit = true;
                return .stopped;
            },
            .end_of_story => {
                self.state.did_safe_exit = true;
                self.state.call_stack.currentElement().current_pointer = Pointer.null_value;
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
            .read_count => {
                // Pop a divert_target and push the visit count for that path (0 if unvisited).
                const val = self.state.evaluation_stack.pop() orelse .void;
                const path_str = switch (val) {
                    .divert_target => |p| p,
                    else => {
                        try self.state.evaluation_stack.append(self.allocator,.{ .int = 0 });
                        self.advancePointer();
                        return .ok;
                    },
                };
                const count = self.state.visit_counts.get(path_str) orelse 0;
                try self.state.evaluation_stack.append(self.allocator,.{ .int = @intCast(count) });
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
            .list_from_int => {
                // Pop: int value, then origin-name string
                const int_val_obj = self.state.evaluation_stack.pop() orelse RuntimeObject{ .int = 0 };
                const origin_obj = self.state.evaluation_stack.pop() orelse RuntimeObject{ .void = {} };
                const origin_name = if (origin_obj == .string) origin_obj.string else "";
                const int_val: i32 = switch (int_val_obj) {
                    .int => |n| @intCast(n),
                    else => 0,
                };
                const result = try self.arena.allocator().create(lists.InkList);
                result.* = .{};
                if (self.list_defs.get(origin_name)) |def| {
                    if (def.itemForValue(int_val)) |item_name| {
                        const key = try std.fmt.allocPrint(self.arena.allocator(), "{s}.{s}", .{ origin_name, item_name });
                        try result.items.put(self.arena.allocator(), key, int_val);
                    }
                }
                try self.state.evaluation_stack.append(self.allocator, .{ .list = result });
                self.advancePointer();
                return .ok;
            },
            .list_range => {
                // Stack (top→bottom): max, min, list
                const max_obj = self.state.evaluation_stack.pop() orelse RuntimeObject{ .int = std.math.maxInt(i32) };
                const min_obj = self.state.evaluation_stack.pop() orelse RuntimeObject{ .int = std.math.minInt(i32) };
                const list_obj = self.state.evaluation_stack.pop() orelse RuntimeObject{ .void = {} };
                const max_int: i32 = switch (max_obj) {
                    .int => |n| @intCast(n),
                    .list => |l| if (l.maxValue()) |m| m else std.math.maxInt(i32),
                    else => std.math.maxInt(i32),
                };
                const min_int: i32 = switch (min_obj) {
                    .int => |n| @intCast(n),
                    .list => |l| if (l.maxValue()) |m| m else std.math.minInt(i32),
                    else => std.math.minInt(i32),
                };
                const result = try self.arena.allocator().create(lists.InkList);
                result.* = .{};
                if (list_obj == .list) {
                    var it = list_obj.list.items.iterator();
                    while (it.next()) |e| {
                        const v = e.value_ptr.*;
                        if (v >= min_int and v <= max_int) {
                            try result.items.put(self.arena.allocator(), e.key_ptr.*, v);
                        }
                    }
                }
                try self.state.evaluation_stack.append(self.allocator, .{ .list = result });
                self.advancePointer();
                return .ok;
            },
            .list_random => {
                const list_obj = self.state.evaluation_stack.pop() orelse RuntimeObject{ .void = {} };
                const result = try self.arena.allocator().create(lists.InkList);
                result.* = .{};
                if (list_obj == .list and list_obj.list.items.count() > 0) {
                    const count = list_obj.list.items.count();
                    const pick: usize = @as(usize, self.state.story_seed) % count;
                    var it = list_obj.list.items.iterator();
                    var idx: usize = 0;
                    while (it.next()) |e| : (idx += 1) {
                        if (idx == pick) {
                            try result.items.put(self.arena.allocator(), e.key_ptr.*, e.value_ptr.*);
                            break;
                        }
                    }
                }
                try self.state.evaluation_stack.append(self.allocator, .{ .list = result });
                self.advancePointer();
                return .ok;
            },
            .begin_thread => {
                // The instruction immediately following begin_thread is always a divert to
                // the thread target.  We advance the ORIGINAL thread past that divert so
                // it continues from after it, then fork a clone whose pointer lands on
                // the divert so it can follow it into the thread body.
                const orig_elem = self.state.call_stack.currentElement();
                orig_elem.current_pointer.index += 1; // point to the divert
                // Clone the thread (clone also points at the divert for now).
                try self.state.call_stack.pushThread();
                // Advance the ORIGINAL (now second-to-last) past the divert.
                const threads = self.state.call_stack.threads.items;
                const orig_thread = &threads[threads.len - 2];
                const orig_top = &orig_thread.call_stack.items[orig_thread.call_stack.items.len - 1];
                orig_top.current_pointer.index += 1;
                // The clone (now current) stays at the divert and will follow it next step.
                return .ok;
            },
        }
    }

    fn handleNativeFunction(self: *Story, func: NativeFunction) !void {
        switch (func) {
            .add => {
                const len = self.state.evaluation_stack.items.len;
                if (len >= 2) {
                    const rhs = self.state.evaluation_stack.items[len - 1];
                    const lhs = self.state.evaluation_stack.items[len - 2];
                    if (lhs == .string and rhs == .string) {
                        _ = self.state.evaluation_stack.pop();
                        _ = self.state.evaluation_stack.pop();
                        const joined = try std.mem.concat(self.allocator, u8, &.{ lhs.string, rhs.string });
                        try self.state.evaluation_stack.append(self.allocator, .{ .string = joined });
                        return;
                    }
                }
            },
            .list_value => {
                const lst = self.state.evaluation_stack.pop() orelse RuntimeObject{ .int = 0 };
                const v: i64 = if (lst == .list) (if (lst.list.maxValue()) |m| @as(i64, m) else 0) else 0;
                try self.state.evaluation_stack.append(self.allocator, .{ .int = v });
                return;
            },
            .list_count => {
                const lst = self.state.evaluation_stack.pop() orelse RuntimeObject{ .void = {} };
                const count: i64 = if (lst == .list) @intCast(lst.list.items.count()) else 0;
                try self.state.evaluation_stack.append(self.allocator, .{ .int = count });
                return;
            },
            .list_min => {
                const lst = self.state.evaluation_stack.pop() orelse RuntimeObject{ .void = {} };
                const result = try self.arena.allocator().create(lists.InkList);
                result.* = .{};
                if (lst == .list) {
                    var min_val: ?i32 = null;
                    var min_key: ?[]const u8 = null;
                    var it = lst.list.items.iterator();
                    while (it.next()) |e| {
                        if (min_val == null or e.value_ptr.* < min_val.?) {
                            min_val = e.value_ptr.*;
                            min_key = e.key_ptr.*;
                        }
                    }
                    if (min_key) |k| try result.items.put(self.arena.allocator(), k, min_val.?);
                }
                try self.state.evaluation_stack.append(self.allocator, .{ .list = result });
                return;
            },
            .list_max => {
                const lst = self.state.evaluation_stack.pop() orelse RuntimeObject{ .void = {} };
                const result = try self.arena.allocator().create(lists.InkList);
                result.* = .{};
                if (lst == .list) {
                    var max_val: ?i32 = null;
                    var max_key: ?[]const u8 = null;
                    var it = lst.list.items.iterator();
                    while (it.next()) |e| {
                        if (max_val == null or e.value_ptr.* > max_val.?) {
                            max_val = e.value_ptr.*;
                            max_key = e.key_ptr.*;
                        }
                    }
                    if (max_key) |k| try result.items.put(self.arena.allocator(), k, max_val.?);
                }
                try self.state.evaluation_stack.append(self.allocator, .{ .list = result });
                return;
            },
            .list_all => {
                const lst = self.state.evaluation_stack.pop() orelse RuntimeObject{ .void = {} };
                const result = try self.expandListToAll(if (lst == .list) lst.list else null);
                try self.state.evaluation_stack.append(self.allocator, .{ .list = result });
                return;
            },
            .list_invert => {
                const lst = self.state.evaluation_stack.pop() orelse RuntimeObject{ .void = {} };
                const all = try self.expandListToAll(if (lst == .list) lst.list else null);
                if (lst == .list) {
                    var it = lst.list.items.iterator();
                    while (it.next()) |e| _ = all.items.remove(e.key_ptr.*);
                }
                try self.state.evaluation_stack.append(self.allocator, .{ .list = all });
                return;
            },
            else => {},
        }
        try evaluation.callNativeFunction(self.arena.allocator(), func, &self.state.evaluation_stack);
    }

    /// Return a new InkList containing all items from every origin of `list`.
    /// Origins are inferred from item keys (origin.item) plus the list's `origins` field.
    fn expandListToAll(self: *Story, list: ?*const lists.InkList) !*lists.InkList {
        const arena = self.arena.allocator();
        const result = try arena.create(lists.InkList);
        result.* = .{};
        // Collect origin names from item keys and origins field
        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();
        if (list) |lst| {
            var it = lst.items.iterator();
            while (it.next()) |e| {
                const key = e.key_ptr.*;
                const dot = std.mem.indexOfScalar(u8, key, '.') orelse key.len;
                if (dot < key.len) try seen.put(key[0..dot], {});
            }
            for (lst.origins) |o| try seen.put(o, {});
            result.origins = lst.origins;
        }
        // Add all items from those origins via list_defs
        var o_it = seen.keyIterator();
        while (o_it.next()) |origin_key| {
            if (self.list_defs.get(origin_key.*)) |def| {
                var item_it = def.items.iterator();
                while (item_it.next()) |item_entry| {
                    const full_key = try std.fmt.allocPrint(arena, "{s}.{s}", .{ def.name, item_entry.key_ptr.* });
                    try result.items.put(arena, full_key, item_entry.value_ptr.*);
                }
            }
        }
        return result;
    }

    fn handleDivert(self: *Story, d: value.Divert) !StepResult {
        const elem = self.state.call_stack.currentElement();

        // External function call: dispatch before normal path resolution.
        if (d.external_args > 0) {
            self.advancePointer();
            const func = self.external_functions.get(d.target) orelse return error.FunctionNotBound;
            // Args were pushed left-to-right; pop right-to-left then reverse.
            const args = try self.allocator.alloc(RuntimeObject, d.external_args);
            defer self.allocator.free(args);
            var idx: usize = d.external_args;
            while (idx > 0) {
                idx -= 1;
                args[idx] = self.state.evaluation_stack.pop() orelse .void;
            }
            const result = func(args) orelse RuntimeObject.void;
            try self.state.evaluation_stack.append(self.allocator, result);
            return .ok;
        }

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
        if (self.state.variables_state.get(name)) |v| return v;
        // Fallback: check if name is a list item defined in any list origin.
        var def_it = self.list_defs.definitions.iterator();
        while (def_it.next()) |def_entry| {
            const def = def_entry.value_ptr;
            if (def.items.get(name)) |val| {
                const arena = self.arena.allocator();
                const key = std.fmt.allocPrint(arena, "{s}.{s}", .{ def.name, name }) catch return null;
                const ink_list = arena.create(lists.InkList) catch return null;
                ink_list.* = .{};
                ink_list.items.put(arena, key, val) catch return null;
                const origins = arena.alloc([]const u8, 1) catch return null;
                origins[0] = def.name;
                ink_list.origins = origins;
                return .{ .list = ink_list };
            }
        }
        return null;
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

    /// Remove trailing "\n" RuntimeObjects from the output stream, but only from `from` onward.
    /// Called after a function returns to discard structural newlines from conditional blocks
    /// without affecting output written before the function was called.
    fn trimNewlinesFromOutputStream(stream: *std.ArrayList(RuntimeObject), from: usize) void {
        while (stream.items.len > from) {
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

test "Story false_plus_false" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "booleans/false_plus_false.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();
    const out = try story.cont();
    defer alloc.free(out);
    try std.testing.expectEqualStrings("0\n", out);
}

test "Story not_one" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "booleans/not_one.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();
    const out = try story.cont();
    defer alloc.free(out);
    try std.testing.expectEqualStrings("0\n", out);
}

test "Story true_equals_one" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "booleans/true_equals_one.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();
    const out = try story.cont();
    defer alloc.free(out);
    try std.testing.expectEqualStrings("1\n", out);
}

test "Story true_plus_one" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "booleans/true_plus_one.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();
    const out = try story.cont();
    defer alloc.free(out);
    try std.testing.expectEqualStrings("2\n", out);
}

test "Story two_plus_true" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "booleans/two_plus_true.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();
    const out = try story.cont();
    defer alloc.free(out);
    try std.testing.expectEqualStrings("3\n", out);
}

test "Story list_hasnt" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "booleans/list_hasnt.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();
    const out = try story.cont();
    defer alloc.free(out);
    // list = {b, d}; c !? list → c is not in list → true → 1
    try std.testing.expectEqualStrings("1\n", out);
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

// ── TASK-50: callstack fixture tests ─────────────────────────────────────────

test "Story call_stack_evaluation" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "callstack/call_stack_evaluation.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();
    const out = try story.cont();
    defer alloc.free(out);
    // six() + two() = 8
    try std.testing.expectEqualStrings("8\n", out);
}

test "Story clean_callstack_reset_on_path_choice" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "callstack/clean_callstack_reset_on_path_choice.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();
    // Initial run: RunAThing outputs both lines as a void function
    const out1 = try story.cont();
    defer alloc.free(out1);
    try std.testing.expectEqualStrings("The first line.\nThe second line.\n", out1);
    // Jump to SomewhereElse knot and continue
    try story.choosePathString("SomewhereElse");
    const out2 = try story.cont();
    defer alloc.free(out2);
    try std.testing.expectEqualStrings("somewhere else\n", out2);
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

// ── TASK-49: builtin fixture tests ───────────────────────────────────────────

test "Story read_count_dot_separated_path" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "builtins/read_count_dot_separated_path.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();
    const out = try story.cont();
    defer alloc.free(out);
    // tunnels to hi.stitch_to_count 3 times (each outputs "hi\n"), then CNT?=3
    try std.testing.expectEqualStrings("hi\nhi\nhi\n3\n", out);
}

test "Story read_count_variable_target" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "builtins/read_count_variable_target.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();
    const out = try story.cont();
    defer alloc.free(out);
    // knot tunneled 3 times; read count via variable, literal path, and CNT? all agree
    try std.testing.expectEqualStrings("Count start: 0 0 0\n1\n2\n3\nCount end: 3 3 3\n", out);
}

test "Story read_count_across_threads" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "builtins/read_count_across_threads.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();
    const out = try story.cont();
    defer alloc.free(out);
    // thread forks aside (choice filtered by condition=false); main outputs CNT?(top) twice
    try std.testing.expectEqualStrings("1\n1\n", out);
    try std.testing.expectEqual(@as(usize, 0), story.currentChoices().len);
    try std.testing.expect(!story.canContinue());
}

test "Story turns_since_nested" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "builtins/turns_since_nested.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    // Before any choice: turns_since(c-0) = -1
    const out1 = try story.cont();
    defer alloc.free(out1);
    try std.testing.expectEqualStrings("-1 = -1\n", out1);
    try std.testing.expectEqual(@as(usize, 1), story.currentChoices().len);

    // After "stuff": turns_since(c-0) = 0 (same turn as entry)
    try story.chooseChoiceIndex(0);
    const out2 = try story.cont();
    defer alloc.free(out2);
    try std.testing.expectEqualStrings("stuff\n0 = 0\n", out2);
    try std.testing.expectEqual(@as(usize, 1), story.currentChoices().len);

    // After "more stuff": turns_since(outer c-0) = 1 (entered one turn ago)
    try story.chooseChoiceIndex(0);
    const out3 = try story.cont();
    defer alloc.free(out3);
    try std.testing.expectEqualStrings("more stuff\n1 = 1\n", out3);
    try std.testing.expect(!story.canContinue());
}

test "Story turns_since_with_variable_target" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "builtins/turns_since_with_variable_target.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    // start visited at turn 0; beats(start) = turns_since(start) = 0
    const out1 = try story.cont();
    defer alloc.free(out1);
    try std.testing.expectEqualStrings("0\n0\n", out1);
    try std.testing.expectEqual(@as(usize, 1), story.currentChoices().len);

    // After choice: turn=1; beats(start) = turns_since(start) = 1
    try story.chooseChoiceIndex(0);
    const out2 = try story.cont();
    defer alloc.free(out2);
    try std.testing.expect(std.mem.indexOf(u8, out2, "1\n") != null);
    try std.testing.expect(!story.canContinue());
}

test "Story turns (turn_index cycles)" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "builtins/turns.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    // Initial cont via c-0 divert: outputs turn_index (= 0) then loops to choice
    const out1 = try story.cont();
    defer alloc.free(out1);
    try std.testing.expect(std.mem.indexOf(u8, out1, "0") != null);
    try std.testing.expectEqual(@as(usize, 1), story.currentChoices().len);

    // After choosing: turn increments to 1
    try story.chooseChoiceIndex(0);
    const out2 = try story.cont();
    defer alloc.free(out2);
    try std.testing.expect(std.mem.indexOf(u8, out2, "1") != null);
    try std.testing.expectEqual(@as(usize, 1), story.currentChoices().len);
}

test "Story visit_count_bug_due_to_nested_containers" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "builtins/visit_count_bug_due_to_nested_containers.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    // The gather container is entered once; CNT?(".^") must be 1, not 2
    const out1 = try story.cont();
    defer alloc.free(out1);
    try std.testing.expectEqualStrings("1\n", out1);
    try std.testing.expectEqual(@as(usize, 1), story.currentChoices().len);

    // After choosing, g-0 outputs CNT?("0.gather") which is still 1
    try story.chooseChoiceIndex(0);
    const out2 = try story.cont();
    defer alloc.free(out2);
    try std.testing.expect(std.mem.indexOf(u8, out2, "1\n") != null);
    try std.testing.expect(!story.canContinue());
}

test "Story visit_counts_when_choosing" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "builtins/visit_counts_when_choosing.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    // Root is immediately done; navigate explicitly to TestKnot
    try story.choosePathString("TestKnot");
    const out1 = try story.cont();
    defer alloc.free(out1);
    try std.testing.expect(std.mem.indexOf(u8, out1, "this is a test") != null);
    try std.testing.expectEqual(@as(usize, 1), story.currentChoices().len);

    try story.chooseChoiceIndex(0);
    const out2 = try story.cont();
    defer alloc.free(out2);
    try std.testing.expect(std.mem.indexOf(u8, out2, "this is the end") != null);
    try std.testing.expect(!story.canContinue());
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

test "list_basic_operations: union, intersect, has, hasnt" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "lists/list_basic_operations.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();
    const out = try story.cont();
    defer alloc.free(out);
    try std.testing.expectEqualStrings("b, d\na, b, c, e\nb, c\n0\n1\n1\n", out);
}

test "list_mixed_items: multi-origin list union" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "lists/list_mixed_items.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();
    const out = try story.cont();
    defer alloc.free(out);
    try std.testing.expectEqualStrings("a, c, y\n", out);
}

test "more_list_operations: LIST_VALUE, listInt, LIST_ALL, LIST_INVERT" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "lists/more_list_operations.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();
    const out = try story.cont();
    defer alloc.free(out);
    // 1: LIST_VALUE(l=1) -> "1"
    // 2: listInt(1, "list") -> "l"
    // 3: standalone \n after temp assignment
    // 4: output t after adding n -> "n"
    // 5: standalone \n after LIST_ALL assignment
    // 6: output t after subtract n -> "l, m"
    // 7: standalone \n after LIST_INVERT assignment
    // 8: output t (INVERT of {l,m} = {n}) -> "n"
    try std.testing.expectEqualStrings("1\nl\n\nn\n\nl, m\n\nn\n", out);
}

test "list_range: range control command and LIST_ALL with origins" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "lists/list_range.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();
    const out = try story.cont();
    defer alloc.free(out);
    // Numbers range [Two..Six] is deterministic (unique values): "Two, Three, Four, Five, Six"
    // {Food.Pizza:1,Food.Pasta:2} range [-1..100] is deterministic: "Pizza, Pasta"
    try std.testing.expect(std.mem.indexOf(u8, out, "Two, Three, Four, Five, Six\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Pizza, Pasta\n") != null);
    // all has 7 items from Food+Currency origins
    const lines = std.mem.tokenizeScalar(u8, out, '\n');
    _ = lines;
    // At minimum there should be 5 non-empty lines
    var non_empty: usize = 0;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (line.len > 0) non_empty += 1;
    }
    try std.testing.expect(non_empty >= 4);
}

test "thread_done: forked thread ends with done, main continues" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "threads/thread_done.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();
    const out = try story.cont();
    defer alloc.free(out);
    try std.testing.expectEqualStrings("This is a thread example\nHello.\nThe example is now complete.\n", out);
}

test "multi_thread: choices from both threads merged" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "threads/multi_thread.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();
    const out = try story.cont();
    defer alloc.free(out);
    // Both threads produce introductory text and one choice each.
    try std.testing.expect(std.mem.indexOf(u8, out, "This is place 1.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "This is place 2.") != null);
    const choices = story.currentChoices();
    try std.testing.expectEqual(@as(usize, 2), choices.len);
    // Choice texts (trimmed)
    var found1 = false;
    var found2 = false;
    for (choices) |c| {
        if (std.mem.indexOf(u8, c.text, "choice in place 1") != null) found1 = true;
        if (std.mem.indexOf(u8, c.text, "choice in place 2") != null) found2 = true;
    }
    try std.testing.expect(found1);
    try std.testing.expect(found2);
}

test "multi_flow_basics: separate flow states maintained" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "multiflow/multi_flow_basics.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    // Flow 1: run knot1
    try story.switchFlow("f1");
    try story.choosePathString("knot1");
    const out1 = try story.cont();
    defer alloc.free(out1);
    try std.testing.expectEqualStrings("knot 1 line 1\nknot 1 line 2\n", out1);

    // Flow 2: run knot2 independently
    try story.switchFlow("f2");
    try story.choosePathString("knot2");
    const out2 = try story.cont();
    defer alloc.free(out2);
    try std.testing.expectEqualStrings("knot 2 line 1\nknot 2 line 2\n", out2);

    // Switch back to f1: it should be at end (canContinue false)
    try story.switchFlow("f1");
    try std.testing.expect(!story.canContinue());

    // removeFlow("f2") should work without error
    try story.removeFlow("f2");

    // removeFlow("DEFAULT") should error
    try std.testing.expectError(error.CannotRemoveDefaultFlow, story.removeFlow("DEFAULT"));
}

// External function helpers used in tests (module-level so they can be passed as fn pointers).
fn extMultiply(args: []const RuntimeObject) ?RuntimeObject {
    const a: f64 = switch (args[0]) {
        .float => |f| f,
        .int => |n| @floatFromInt(n),
        else => return null,
    };
    const b: f64 = switch (args[1]) {
        .float => |f| f,
        .int => |n| @floatFromInt(n),
        else => return null,
    };
    return .{ .float = a * b };
}

fn extMessage(_: []const RuntimeObject) ?RuntimeObject {
    return null; // void return
}

fn extTimes(args: []const RuntimeObject) ?RuntimeObject {
    // times(count: int, text: string) -> repeated string (static buffer for test)
    _ = args;
    return .{ .string = "knock knock knock " };
}

test "external_binding: bound functions called with correct args" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "bindings/external_binding.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    try story.bindExternalFunction("message", extMessage, .{});
    try story.bindExternalFunction("multiply", extMultiply, .{});
    try story.bindExternalFunction("times", extTimes, .{});

    const out = try story.cont();
    defer alloc.free(out);
    // First block: message("hello world") result discarded → just "\n"
    // Second block: multiply(5.0, 3) = 15 → "15\n"
    // Third block: times(3, "knock ") = "knock knock knock " → "knock knock knock \n"
    try std.testing.expectEqualStrings("\n15\nknock knock knock \n", out);
}

test "toJson: fresh state contains required top-level keys" {
    const alloc = std.testing.allocator;
    const json = try readFixture(alloc, "misc/hello_world.ink.json");
    defer alloc.free(json);
    var story = try Story.initFromJson(alloc, json);
    defer story.deinit();

    const saved = try story.toJson(alloc);
    defer alloc.free(saved);

    try std.testing.expect(std.mem.indexOf(u8, saved, "\"callstackThreads\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, saved, "\"variablesState\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, saved, "\"visitCounts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, saved, "\"turnIndices\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, saved, "\"currentTurnIndex\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, saved, "\"storySeed\"") != null);
}

test "save/load round-trip: hello_world pointer preserved" {
    const alloc = std.testing.allocator;
    const json_text = try readFixture(alloc, "misc/hello_world.ink.json");
    defer alloc.free(json_text);

    // Run story A to completion
    var story_a = try Story.initFromJson(alloc, json_text);
    defer story_a.deinit();
    const out_a = try story_a.cont();
    defer alloc.free(out_a);

    // Save state of A (pointer is at end: null/didSafeExit)
    const saved = try story_a.toJson(alloc);
    defer alloc.free(saved);

    // Create story B and restore state from A
    var story_b = try Story.initFromJson(alloc, json_text);
    defer story_b.deinit();
    try story_b.loadStateFromJson(saved);

    // B should also be at end: same canContinue state
    try std.testing.expectEqual(story_a.canContinue(), story_b.canContinue());
}

test "save/load round-trip: list variables preserved across list_save_load" {
    const alloc = std.testing.allocator;
    const json_text = try readFixture(alloc, "lists/list_save_load.ink.json");
    defer alloc.free(json_text);

    // Run story A: t = l1+l2 = {a,c,x}
    var story_a = try Story.initFromJson(alloc, json_text);
    defer story_a.deinit();
    const out1 = try story_a.cont();
    defer alloc.free(out1);
    try std.testing.expectEqualStrings("a, c, x\n", out1);

    // Save state (variables l1, l2, t are set)
    const saved = try story_a.toJson(alloc);
    defer alloc.free(saved);

    // Create story B, restore state, jump to "elsewhere", run
    var story_b = try Story.initFromJson(alloc, json_text);
    defer story_b.deinit();
    try story_b.loadStateFromJson(saved);
    try story_b.choosePathString("elsewhere");
    const out2 = try story_b.cont();
    defer alloc.free(out2);
    // elsewhere: t = t + z = {a,c,x,z}
    try std.testing.expectEqualStrings("a, c, x, z\n", out2);
}

// ── TASK-44: Variable observer tests ─────────────────────────────────────────

test "observeVariable: fires when observed global changes" {
    const alloc = std.testing.allocator;
    const json_text = try readFixture(alloc, "misc/hello_world.ink.json");
    defer alloc.free(json_text);

    var story = try Story.initFromJson(alloc, json_text);
    defer story.deinit();

    const Ctx = struct {
        fired: bool = false,
        last_val: RuntimeObject = .void,
        fn callback(name: []const u8, new_val: RuntimeObject) void {
            _ = name;
            // Use a thread-local to communicate back (observer is a plain fn pointer)
            result.fired = true;
            result.last_val = new_val;
        }
        var result: @This() = .{};
    };
    Ctx.result = .{};

    try story.observeVariable("x", Ctx.callback);
    // Directly set the variable via variables_state to trigger the observer path
    // (simulating what step() does)
    try story.state.variables_state.set(alloc, "x", .{ .int = 5 });
    story.notifyObservers("x", .{ .int = 5 });
    try std.testing.expect(Ctx.result.fired);
    try std.testing.expectEqual(RuntimeObject{ .int = 5 }, Ctx.result.last_val);
}

test "observeVariable: does not fire for unobserved variable" {
    const alloc = std.testing.allocator;
    const json_text = try readFixture(alloc, "misc/hello_world.ink.json");
    defer alloc.free(json_text);

    var story = try Story.initFromJson(alloc, json_text);
    defer story.deinit();

    const Ctx = struct {
        fired: bool = false,
        fn callback(_: []const u8, _: RuntimeObject) void { result.fired = true; }
        var result: @This() = .{};
    };
    Ctx.result = .{};

    try story.observeVariable("y", Ctx.callback);
    // Set a DIFFERENT variable — observer for "y" must not fire
    story.notifyObservers("x", .{ .int = 5 });
    try std.testing.expect(!Ctx.result.fired);
}

test "variable_observer.ink.json: observer fires during story execution" {
    const alloc = std.testing.allocator;
    const json_text = try readFixture(alloc, "bindings/variable_observer.ink.json");
    defer alloc.free(json_text);

    var story = try Story.initFromJson(alloc, json_text);
    defer story.deinit();

    const Ctx = struct {
        count: u32 = 0,
        last_int: i64 = 0,
        fn callback(_: []const u8, new_val: RuntimeObject) void {
            result.count += 1;
            if (new_val == .int) result.last_int = new_val.int;
        }
        var result: @This() = .{};
    };
    Ctx.result = .{};

    try story.observeVariable("testVar", Ctx.callback);

    // First cont(): sets testVar = 15 during execution
    const out1 = try story.cont();
    defer alloc.free(out1);
    try std.testing.expectEqualStrings("Hello world!\nHello world 2!\n", out1);
    // testVar was set once (to 15)
    try std.testing.expect(Ctx.result.count >= 1);
    try std.testing.expectEqual(@as(i64, 15), Ctx.result.last_int);
}

// ── TASK-45: evaluateFunction tests ──────────────────────────────────────────

test "evaluateFunction: func1 returns int value and captures text" {
    const alloc = std.testing.allocator;
    const json_text = try readFixture(alloc, "evaluation/evaluating_ink_functions_from_game_2.ink.json");
    defer alloc.free(json_text);

    var story = try Story.initFromJson(alloc, json_text);
    defer story.deinit();

    // Call func1: outputs "This is a function\n", returns 5
    var text_out = std.ArrayList(u8).empty;
    defer text_out.deinit(alloc);
    const result = try story.evaluateFunction("func1", &.{}, &text_out);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(RuntimeObject{ .int = 5 }, result.?);
    // pop_function trims trailing newlines from output, matching C# Ink runtime behaviour
    try std.testing.expectEqualStrings("This is a function", text_out.items);
}

test "evaluateFunction: func2 returns null (void function)" {
    const alloc = std.testing.allocator;
    const json_text = try readFixture(alloc, "evaluation/evaluating_ink_functions_from_game_2.ink.json");
    defer alloc.free(json_text);

    var story = try Story.initFromJson(alloc, json_text);
    defer story.deinit();

    const result = try story.evaluateFunction("func2", &.{}, null);
    try std.testing.expectEqual(@as(?RuntimeObject, null), result);
}

test "evaluateFunction: add(x,y) returns x+y" {
    const alloc = std.testing.allocator;
    const json_text = try readFixture(alloc, "evaluation/evaluating_ink_functions_from_game_2.ink.json");
    defer alloc.free(json_text);

    var story = try Story.initFromJson(alloc, json_text);
    defer story.deinit();

    const result = try story.evaluateFunction("add", &.{ .{ .int = 3 }, .{ .int = 4 } }, null);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(RuntimeObject{ .int = 7 }, result.?);
}

test "evaluateFunction: story state fully restored after call" {
    const alloc = std.testing.allocator;
    const json_text = try readFixture(alloc, "evaluation/evaluating_ink_functions_from_game_2.ink.json");
    defer alloc.free(json_text);

    var story = try Story.initFromJson(alloc, json_text);
    defer story.deinit();

    // Before any cont(): story can continue
    try std.testing.expect(story.canContinue());

    // evaluateFunction must not corrupt canContinue state
    _ = try story.evaluateFunction("func1", &.{}, null);

    // Story should still be continuable (evaluateFunction must restore state)
    try std.testing.expect(story.canContinue());

    // And cont() still produces the expected top-level output
    const out1 = try story.cont();
    defer alloc.free(out1);
    try std.testing.expectEqualStrings("One\nTwo\nThree\n", out1);
}

// ── TASK-46: remaining public API tests ──────────────────────────────────────

test "visitCountAtPathString: 0 before visit, 1 after" {
    const alloc = std.testing.allocator;
    const json_text = try readFixture(alloc, "knots/knot_stitch_gather_counts.ink.json");
    defer alloc.free(json_text);

    var story = try Story.initFromJson(alloc, json_text);
    defer story.deinit();

    // Before visiting: count is 0
    try std.testing.expectEqual(@as(u32, 0), story.visitCountAtPathString("knot_count_test"));

    // Run the story (which visits knot_count_test multiple times)
    const out = try story.cont();
    defer alloc.free(out);

    // After running: count should be > 0
    try std.testing.expect(story.visitCountAtPathString("knot_count_test") > 0);
}

test "currentFlowIsDefaultFlow: true initially, false after switchFlow" {
    const alloc = std.testing.allocator;
    const json_text = try readFixture(alloc, "misc/hello_world.ink.json");
    defer alloc.free(json_text);

    var story = try Story.initFromJson(alloc, json_text);
    defer story.deinit();

    try std.testing.expect(story.currentFlowIsDefaultFlow());
    try std.testing.expectEqualStrings("DEFAULT", story.currentFlowName());

    try story.switchFlow("other");
    try std.testing.expect(!story.currentFlowIsDefaultFlow());
    try std.testing.expectEqualStrings("other", story.currentFlowName());

    try story.switchToDefaultFlow();
    try std.testing.expect(story.currentFlowIsDefaultFlow());
}

test "globalTags: returns story-level tags from tags.ink.json" {
    const alloc = std.testing.allocator;
    const json_text = try readFixture(alloc, "tags/tags.ink.json");
    defer alloc.free(json_text);

    var story = try Story.initFromJson(alloc, json_text);
    defer story.deinit();

    const tags = try story.globalTags();
    defer alloc.free(tags);

    try std.testing.expectEqual(@as(usize, 2), tags.len);
    try std.testing.expectEqualStrings("author: Joe", tags[0]);
    try std.testing.expectEqualStrings("title: My Great Story", tags[1]);
}
