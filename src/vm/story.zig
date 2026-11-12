//! A story on the new runtime (plan §4.6, §4.7): a borrowed program, one state, and ink's
//! Continue loop around the VM. The public API (P6) wraps this.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Program = @import("../core/program.zig").Program;
const Limits = @import("../core/limits.zig").Limits;
const state_module = @import("state.zig");
const call_stack_module = @import("call_stack.zig");
const output_module = @import("output.zig");
const choices_module = @import("choices.zig");
const value_module = @import("value.zig");
const lookahead = @import("lookahead.zig");
const vm = @import("vm.zig");
const ops = @import("ops.zig");
const messages = @import("messages.zig");
const flows = @import("flows.zig");
const State = state_module.State;
const Pointer = call_stack_module.Pointer;
const StringReference = value_module.StringReference;
const index = @import("../core/index.zig");
const ContainerIndex = index.ContainerIndex;
const Lists = @import("lists.zig").Lists;

pub const Error = error{
    /// A story error was recorded (ink's StoryException); see `State.errors`.
    StoryError,
    EvaluationLimit,
    FrameLimit,
    ThreadLimit,
    TempLimit,
    OutputLimit,
    TextTooLong,
    HeapLimit,
    ListLimit,
    ChoiceLimit,
    TagLimit,
    SnapshotLimit,
    LookaheadLogLimit,
    StepLimit,
    /// An external function the story calls has no binding (and no fallback); see
    /// `Story.missing_externals` (ink's ValidateExternalBindings, at the first `cont`).
    MissingExternalBinding,
    /// More globals changed in one `cont` than `observer_events_max`.
    ObserverQueueLimit,
    /// A mutating call from inside a callback (only evaluate_function may nest).
    Reentrant,
    /// A bound external function returned an error.
    ExternalFunctionFailed,
};

/// A value as a host sees it: strings are slices, valid only until the story's next
/// mutating call (and, in a callback, only during the callback).
pub const HostValue = union(enum) {
    null,
    integer: i32,
    float: f32,
    bool: bool,
    string: []const u8,
    list: value_module.ListReference,
    divert_target: ContainerIndex,
};

/// An external function (plan §4.7, D22). It may call `evaluate_function` on `story`.
pub const ExternalFunction = *const fn (
    context: ?*anyopaque,
    story: *Story,
    arguments: []const HostValue,
) anyerror!HostValue;

pub const Binding = struct {
    function: ?ExternalFunction = null,
    context: ?*anyopaque = null,
    /// ink's lookaheadSafe: whether calling it during the newline lookahead is harmless.
    lookahead_safe: bool = true,
};

/// Receives each error and warning message at the end of `cont`, as ink's onError does.
pub const ErrorHandler = *const fn (
    context: ?*anyopaque,
    message: []const u8,
    severity: state_module.Diagnostic.Severity,
) void;

/// A variable observer (ink's VariableObserver): the global's name and new value.
pub const Observer = *const fn (context: ?*anyopaque, name: []const u8, value: HostValue) void;

/// ink's host events (D22), each optional, each called with `context`, at ink's points:
/// after each Continue, before a choice is taken, around evaluate_function and at the start
/// of choose_path_string.
pub const Events = struct {
    context: ?*anyopaque = null,
    on_did_continue: ?*const fn (context: ?*anyopaque) void = null,
    on_make_choice: ?*const fn (context: ?*anyopaque, text: []const u8, position: u32) void = null,
    on_evaluate_function: ?*const fn (
        context: ?*anyopaque,
        name: []const u8,
        arguments: []const HostValue,
    ) void = null,
    on_complete_evaluate_function: ?*const fn (
        context: ?*anyopaque,
        name: []const u8,
        arguments: []const HostValue,
        text: []const u8,
        result: HostValue,
    ) void = null,
    on_choose_path_string: ?*const fn (
        context: ?*anyopaque,
        path: []const u8,
        arguments: []const HostValue,
    ) void = null,
};

/// The most arguments an external function can take.
pub const external_arguments_max = 32;

pub const SetError = Error || error{VariableNotDeclared};

pub const Story = struct {
    program: *const Program,
    state: State,
    /// ink's divertedPointer: where the next NextContent goes. Only set within a step.
    diverted_pointer: Pointer = .null,
    saw_lookahead_unsafe_function_after_newline: bool = false,
    /// The cleaned text length and tag count when the lookahead snapshot was taken.
    snapshot_text_length: u32 = 0,
    snapshot_tags_count: u32 = 0,
    /// The last line returned by `cont`, in `state.line_bytes`.
    line_length: u32 = 0,
    /// Instructions run since init, for benchmarks.
    steps_total: u64 = 0,
    /// One per program external, by ExternalIndex.
    bindings: []Binding,
    /// ink's allowExternalFunctionFallbacks.
    allow_external_function_fallbacks: bool = false,
    /// ink's _hasValidatedExternals: bindings are checked once, at the first `cont`.
    has_validated_externals: bool = false,
    /// ink's onError. Without one, `cont` returns `error.StoryError` when the story
    /// recorded an error or warning, and keeps them in `state` (ink throws instead).
    on_error: ?ErrorHandler = null,
    on_error_context: ?*anyopaque = null,
    /// How many observers `state.observers` holds; they survive `reset_state`, as in ink.
    observers_count: u32 = 0,
    /// Nesting of ContinueInternal (evaluate_function from an external function nests).
    continue_depth: u32 = 0,
    /// ink's batchObservingVariableChanges: inside the outermost ContinueInternal, changed
    /// globals are queued in `state.observer_events` and notified at its end.
    batching_observers: bool = false,
    /// Callbacks running now (externals, observers, the error handler).
    callback_depth: u32 = 0,
    /// evaluate_function calls running now.
    evaluate_depth: u32 = 0,
    events: Events = .{},

    pub fn init(story: *Story, gpa: Allocator, program: *const Program, limits: Limits) !void {
        assert(program.containers.len > 0);
        const bindings = try gpa.alloc(Binding, program.externals.len);
        errdefer gpa.free(bindings);
        @memset(bindings, .{});
        story.* = .{ .program = program, .state = undefined, .bindings = bindings };
        try story.state.init(gpa, program, limits);
        errdefer story.state.deinit(gpa);
        try story.reset_globals();
        assert(story.state.call_stack.depth() == 1);
    }

    /// ink's ResetState: a fresh state, with the global declaration run again.
    pub fn reset_state(story: *Story) Error!void {
        assert(story.state.memory.len > 0);
        if (story.callback_depth > 0) return error.Reentrant;
        story.state.reset();
        story.diverted_pointer = .null;
        try story.reset_globals();
        assert(story.state.call_stack.depth() == 1);
    }

    /// Seeds RANDOM and shuffles (`Options.random_seed`): ink's storySeed, with
    /// previousRandom reset. ink seeds from the clock; this runtime starts at 0.
    pub fn set_random_seed(story: *Story, seed: i32) void {
        assert(story.state.memory.len > 0);
        story.state.story_seed = seed;
        story.state.previous_random = 0;
        assert(story.state.story_seed == seed);
    }

    /// ink's SwitchFlow: makes flow `name` current, creating it at the root if it's new.
    pub fn switch_flow(story: *Story, name: []const u8) (Error || flows.Error)!void {
        assert(name.len > 0);
        if (story.callback_depth > 0) return error.Reentrant;
        try flows.switch_flow(&story.state, name);
        assert(std.mem.eql(u8, flows.current_name(&story.state), name));
    }

    /// ink's SwitchToDefaultFlow.
    pub fn switch_to_default_flow(story: *Story) (Error || flows.Error)!void {
        assert(story.state.flows[0].in_use);
        assert(story.state.flows.len > 0);
        try story.switch_flow(flows.default_name);
    }

    /// ink's RemoveFlow.
    pub fn remove_flow(story: *Story, name: []const u8) (Error || flows.Error)!void {
        assert(story.state.flows[0].in_use);
        assert(name.len > 0);
        if (story.callback_depth > 0) return error.Reentrant;
        try flows.remove_flow(&story.state, name);
    }

    /// ink's BindExternalFunctionGeneral. Names the story never calls are ignored.
    pub fn bind_external_function(
        story: *Story,
        name: []const u8,
        function: ExternalFunction,
        context: ?*anyopaque,
        lookahead_safe: bool,
    ) error{AlreadyBound}!void {
        assert(name.len > 0);
        const external = story.program.external_by_name(name) orelse return;
        const binding = &story.bindings[external.to_int()];
        if (binding.function != null) return error.AlreadyBound;
        binding.* = .{ .function = function, .context = context, .lookahead_safe = lookahead_safe };
        assert(story.bindings[external.to_int()].function != null);
    }

    /// ink's UnbindExternalFunction.
    pub fn unbind_external_function(story: *Story, name: []const u8) error{NotBound}!void {
        assert(name.len > 0);
        const external = story.program.external_by_name(name) orelse return error.NotBound;
        const binding = &story.bindings[external.to_int()];
        if (binding.function == null) return error.NotBound;
        binding.* = .{};
        assert(story.bindings[external.to_int()].function == null);
    }

    /// Calls `sink.name(text)` for each external with no binding and no usable fallback, in
    /// the order the story first uses them (ink's missingExternals).
    pub fn missing_externals(story: *const Story, sink: anytype) !void {
        assert(@typeInfo(@TypeOf(sink)) == .pointer);
        assert(story.bindings.len == story.program.externals.len);
        for (story.program.externals, story.bindings) |external, binding| {
            if (binding.function != null) continue;
            if (story.allow_external_function_fallbacks and !external.fallback.is_none()) continue;
            try sink.name(story.program.strings.get(external.name));
        }
    }

    fn validate_external_bindings(story: *Story) Error!void {
        assert(!story.has_validated_externals);
        assert(story.bindings.len == story.program.externals.len);
        story.has_validated_externals = true;
        var counter: NameCounter = .{};
        story.missing_externals(&counter) catch unreachable;
        if (counter.count > 0) return error.MissingExternalBinding;
    }

    pub fn deinit(story: *Story, gpa: Allocator) void {
        gpa.free(story.bindings);
        const shape = State.shape_of(story.program);
        assert(story.state.memory.len == story.state.limits.bytes_total(shape));
        assert(story.state.memory.len > 0);
        story.state.deinit(gpa);
        story.* = undefined;
    }

    pub fn program_newline(story: *const Story) StringReference {
        assert(story.program.strings.get(story.program.newline).len == 1);
        assert(!story.program.newline.is_none());
        return .program(story.program.newline);
    }

    /// ink's ResetGlobals: runs `global decl` from its start, then keeps the defaults.
    fn reset_globals(story: *Story) Error!void {
        assert(story.state.call_stack.depth() == 1);
        const declaration = story.program.global_declaration;
        if (!declaration.is_none()) {
            const original = vm.current_pointer(story);
            try story.choose_pointer(.start_of(declaration), false);
            _ = try story.continue_internal();
            story.state.call_stack.current_frame().pointer = original;
        }
        @memcpy(story.state.global_defaults, story.state.globals);
        assert(story.state.global_defaults.len == story.state.globals.len);
    }

    /// ink's canContinue.
    pub fn can_continue(story: *Story) bool {
        assert(story.state.call_stack.depth() > 0);
        assert(story.state.memory.len > 0);
        return !vm.current_pointer(story).is_null() and !story.state.has_error();
    }

    /// ink's Continue: the next line. Story errors stay in `state.errors`.
    pub fn cont(story: *Story) Error![]const u8 {
        assert(story.state.call_stack.depth() > 0);
        assert(story.state.line_bytes.len > 0);
        if (story.callback_depth > 0) return error.Reentrant;
        return story.next_line();
    }

    /// `cont` without the reentrancy check, for evaluate_function's loop.
    pub fn next_line(story: *Story) Error![]const u8 {
        assert(story.state.line_bytes.len > 0);
        assert(story.can_continue());
        if (!story.has_validated_externals) try story.validate_external_bindings();
        story.state.did_safe_exit = false;
        story.state.output.clear();
        const length = try story.continue_internal();
        story.line_length = length;
        return story.state.line_bytes[0..length];
    }

    /// ink's ContinueMaximally: every line until the story can't continue, written to
    /// `writer`.
    pub fn continue_maximally(story: *Story, writer: *std.Io.Writer) !void {
        assert(story.state.line_bytes.len > 0);
        var lines: u32 = 0;
        while (story.can_continue()) : (lines += 1) {
            assert(lines < std.math.maxInt(u32));
            try writer.writeAll(try story.cont());
        }
        assert(!story.can_continue());
    }

    /// The end of ink's ContinueInternal: each error, then each warning, to the handler,
    /// then ResetErrors.
    fn report_diagnostics(story: *Story) Error!void {
        assert(story.state.memory.len > 0);
        const state = &story.state;
        if (!state.has_error() and !state.has_warning()) return;
        const handler = story.on_error orelse return error.StoryError;
        var buffer: [2048]u8 = undefined;
        const errors = state.errors.slice();
        const lists = [_][]const state_module.Diagnostic{ errors, state.warnings.slice() };
        for (lists) |list| {
            for (list) |diagnostic| {
                var writer: std.Io.Writer = .fixed(&buffer);
                messages.write(story, diagnostic, &writer) catch {};
                story.callback_depth += 1;
                defer story.callback_depth -= 1;
                handler(story.on_error_context, writer.buffered(), diagnostic.severity);
            }
        }
        if (state.diagnostics_dropped > 0) {
            const dropped = state.diagnostics_dropped;
            const text = std.fmt.bufPrint(&buffer, "RUNTIME ERROR: {d} more errors and " ++
                "warnings didn't fit errors_max or warnings_max", .{dropped}) catch &buffer;
            story.callback_depth += 1;
            defer story.callback_depth -= 1;
            handler(story.on_error_context, text, .@"error");
        }
        state.reset_errors();
        assert(!state.has_error());
    }

    /// ink's ContinueInternal, from the loop to the end-of-content checks; returns the
    /// line's length in `line_bytes`.
    fn continue_internal(story: *Story) Error!u32 {
        assert(story.state.call_stack.depth() > 0);
        assert(story.state.limits.steps_per_continue_max > 0);
        story.continue_depth += 1;
        defer story.continue_depth -= 1;
        if (story.continue_depth == 1) {
            story.batching_observers = true;
            story.state.observer_events.clear();
        }
        story.saw_lookahead_unsafe_function_after_newline = false;
        var ends_in_newline = false;
        var steps: u32 = 0;
        const steps_max = story.state.limits.steps_per_continue_max;
        while (true) {
            if (steps == steps_max) return error.StepLimit;
            const result = vm.run(story, steps_max - steps, &steps) catch |err| switch (err) {
                error.StoryError => break,
                else => |other| return other,
            };
            if (result == .budget_exhausted) return error.StepLimit;
            ends_in_newline = story.after_steps() catch |err| switch (err) {
                error.StoryError => break,
                else => |other| return other,
            };
            if (ends_in_newline or !story.can_continue()) break;
        }
        if (ends_in_newline or !story.can_continue()) {
            if (lookahead.active(&story.state)) lookahead.restore(&story.state);
            if (!story.can_continue()) story.check_end_of_content();
            story.state.did_safe_exit = false;
            story.saw_lookahead_unsafe_function_after_newline = false;
            if (story.continue_depth == 1) story.batching_observers = false;
            if (story.events.on_did_continue) |event| {
                story.callback_depth += 1;
                defer story.callback_depth -= 1;
                event(story.events.context);
            }
        }
        story.steps_total += steps;
        const length = try story.write_current_text();
        try story.report_diagnostics();
        // Last, since observers may run more ink.
        if (story.continue_depth == 1 and !story.batching_observers) story.notify_observers();
        return length;
    }

    /// ink's ObserveVariable. Observers of a global are called in the order they were added.
    pub fn observe_variable(
        story: *Story,
        name: []const u8,
        observer: Observer,
        context: ?*anyopaque,
    ) error{ VariableNotDeclared, ObserverLimit }!void {
        assert(name.len > 0);
        const slot = story.program.global_by_name(name) orelse return error.VariableNotDeclared;
        if (story.observers_count == story.state.observers.len) return error.ObserverLimit;
        story.state.observers[story.observers_count] = .{
            .callback = observer,
            .context = context,
            .slot = slot,
        };
        story.observers_count += 1;
        assert(story.observers_count <= story.state.observers.len);
    }

    /// ink's NotifyObservers for the queued globals, with their current values.
    fn notify_observers(story: *Story) void {
        assert(story.continue_depth == 1);
        assert(!story.batching_observers);
        const queued = story.state.observer_events.count;
        var position: u32 = 0;
        while (position < queued) : (position += 1) {
            story.notify_global(story.state.observer_events.buffer[position]);
        }
        story.state.observer_events.clear();
    }

    /// Whether any observer watches global `slot` (only those are queued).
    pub fn is_observed(story: *const Story, slot: index.GlobalSlot) bool {
        assert(story.observers_count <= story.state.observers.len);
        for (story.state.observers[0..story.observers_count]) |record| {
            if (record.slot == slot) return true;
        }
        return false;
    }

    /// Calls the observers of global `slot` with its value now.
    pub fn notify_global(story: *Story, slot: index.GlobalSlot) void {
        assert(story.observers_count <= story.state.observers.len);
        assert(slot.to_int() < story.state.globals.len);
        const name = story.program.strings.get(story.program.globals[slot.to_int()].name);
        for (story.state.observers[0..story.observers_count]) |record| {
            if (record.slot != slot) continue;
            const callback: Observer = @ptrCast(@alignCast(record.callback.?));
            const value = ops.host_value(story, story.state.globals[slot.to_int()]);
            story.callback_depth += 1;
            defer story.callback_depth -= 1;
            callback(record.context, name, value);
        }
    }

    /// The checks of ink's ContinueSingleStep after `vm.run` returns; returns whether the
    /// line is known to have ended.
    fn after_steps(story: *Story) Error!bool {
        assert(story.state.memory.len > 0);
        assert(story.state.call_stack.depth() > 0);
        const state = &story.state;
        const from_game = state.call_stack.current_frame().kind == .function_evaluation_from_game;
        if (!story.can_continue() and !from_game) {
            _ = try story.try_follow_default_invisible_choice();
        }
        if (state.output.in_string_evaluation()) return false;
        if (lookahead.active(state)) {
            const change = try story.newline_change();
            if (change == .extended or story.saw_lookahead_unsafe_function_after_newline) {
                lookahead.restore(state);
                return true;
            }
            if (change == .newline_removed) lookahead.discard(state);
        }
        if (state.output.ends_in_newline()) {
            if (story.can_continue()) {
                if (!lookahead.active(state)) try story.take_snapshot();
            } else if (lookahead.active(state)) {
                lookahead.discard(state);
            }
        }
        return false;
    }

    fn take_snapshot(story: *Story) Error!void {
        assert(!lookahead.active(&story.state));
        story.snapshot_text_length = try story.write_current_text();
        story.snapshot_tags_count = try story.current_tags_count();
        lookahead.take(&story.state);
        assert(lookahead.active(&story.state));
    }

    const Change = enum { none, extended, newline_removed };

    /// ink's CalculateNewlineOutputStateChange, against the snapshot's text and tags.
    fn newline_change(story: *Story) Error!Change {
        assert(lookahead.active(&story.state));
        assert(story.snapshot_text_length <= story.state.line_bytes.len);
        const previous = story.snapshot_text_length;
        const length = try story.write_current_text();
        const text = story.state.line_bytes[0..length];
        const tags = try story.current_tags_count();
        const newline_still_exists =
            length >= previous and previous > 0 and text[previous - 1] == '\n';
        if (tags == story.snapshot_tags_count and length == previous and newline_still_exists) {
            return .none;
        }
        if (!newline_still_exists) return .newline_removed;
        if (tags > story.snapshot_tags_count) return .extended;
        for (text[previous..]) |character| {
            if (character != ' ' and character != '\t') return .extended;
        }
        return .none;
    }

    /// ink's currentText: the output stream's text, cleaned. Valid until the next mutating
    /// call.
    pub fn current_text(story: *Story) Error![]const u8 {
        assert(story.state.output.items.count <= story.state.output.items.capacity());
        assert(story.state.line_bytes.len > 0);
        const length = try story.write_current_text();
        return story.state.line_bytes[0..length];
    }

    /// The current text, cleaned, into `line_bytes`; returns its length.
    fn write_current_text(story: *Story) Error!u32 {
        assert(story.state.line_bytes.len > 0);
        var writer: std.Io.Writer = .fixed(story.state.line_bytes);
        story.state.output.write_text(ops.strings_of(story), &writer) catch
            return error.OutputLimit;
        assert(writer.end <= story.state.line_bytes.len);
        return @intCast(writer.end);
    }

    fn current_tags_count(story: *Story) Error!u32 {
        assert(story.state.memory.len > 0);
        assert(story.state.output.items.count <= story.state.output.items.buffer.len);
        var counter: TagCounter = .{};
        story.state.output.collect_tags(ops.strings_of(story), &counter) catch
            return error.OutputLimit;
        return counter.count;
    }

    /// Calls `sink.tag(text)` for each tag of the current line.
    pub fn current_tags(story: *Story, sink: anytype) !void {
        assert(@typeInfo(@TypeOf(sink)) == .pointer);
        assert(story.state.memory.len > 0);
        try story.state.output.collect_tags(ops.strings_of(story), sink);
    }

    /// ink's end-of-content errors, when the story can't continue.
    fn check_end_of_content(story: *Story) void {
        assert(!story.can_continue());
        assert(story.state.call_stack.depth() > 0);
        const state = &story.state;
        if (state.call_stack.can_pop_thread()) {
            ops.fail(story, .thread_left_to_pop) catch {};
        }
        if (state.choices.count() != 0 or state.did_safe_exit) return;
        const code: state_module.Diagnostic.Code = if (state.call_stack.can_pop(.tunnel))
            .unexpected_end_of_tunnel
        else if (state.call_stack.can_pop(.function))
            .unexpected_end_of_function
        else if (!state.call_stack.can_pop(null))
            .ran_out_of_content
        else
            .unexpected_end_unknown;
        ops.fail(story, code) catch {};
    }

    /// ink's TryFollowDefaultInvisibleChoice.
    fn try_follow_default_invisible_choice(story: *Story) Error!bool {
        assert(!story.can_continue());
        assert(story.state.choices.count() <= story.state.choices.records.buffer.len);
        const choices = &story.state.choices;
        var invisible: ?choices_module.Choice = null;
        for (choices.records.slice()) |choice| {
            if (!choice.invisible_default) return false;
            if (invisible == null) invisible = choice;
        }
        const choice = invisible orelse return false;
        const stack = &story.state.call_stack;
        choices.restore(stack, choice) catch return error.FrameLimit;
        if (lookahead.active(&story.state)) {
            // ink forks the thread so the snapshot's copy stays intact.
            stack.thread_counter += 1;
            stack.current_thread().counter = stack.thread_counter;
        }
        try story.choose_pointer(choice.target, false);
        return true;
    }

    /// ink's ChoosePath with a resolved target.
    pub fn choose_pointer(
        story: *Story,
        target: Pointer,
        incrementing_turn_index: bool,
    ) Error!void {
        assert(target.container.to_int() < story.program.containers.len);
        assert(!target.is_null());
        story.state.choices.clear();
        story.state.call_stack.current_frame().pointer = target;
        if (incrementing_turn_index) story.state.turn_index +%= 1;
        try vm.visit_changed_containers_due_to_divert(story);
    }

    /// The choices shown to the player (ink's currentChoices): none while the story can
    /// continue, and never the invisible defaults.
    pub fn visible_choices_count(story: *Story) u32 {
        if (!story.can_continue()) story.state.choices.indexed_count = story.state.choices.count();
        assert(story.state.choices.count() <= story.state.choices.records.buffer.len);
        if (story.can_continue()) return 0;
        var count: u32 = 0;
        for (story.state.choices.records.slice()) |choice| {
            if (!choice.invisible_default) count += 1;
        }
        assert(count <= story.state.choices.count());
        return count;
    }

    pub fn visible_choice(story: *Story, position: u32) choices_module.Choice {
        assert(story.state.choices.count() > 0);
        assert(position < story.visible_choices_count());
        var seen: u32 = 0;
        for (story.state.choices.records.slice()) |choice| {
            if (choice.invisible_default) continue;
            if (seen == position) return choice;
            seen += 1;
        }
        unreachable;
    }

    /// ink's ChooseChoiceIndex.
    pub fn choose_choice_index(story: *Story, position: u32) Error!void {
        if (story.callback_depth > 0) return error.Reentrant;
        if (story.events.on_make_choice) |event| {
            const text = story.text_of(story.visible_choice(position).text);
            story.callback_depth += 1;
            defer story.callback_depth -= 1;
            event(story.events.context, text, position);
        }
        assert(!story.can_continue());
        const choice = story.visible_choice(position);
        story.state.choices.restore(&story.state.call_stack, choice) catch return error.FrameLimit;
        try story.choose_pointer(choice.target, true);
        assert(story.state.choices.count() == 0);
    }

    /// ink's `variablesState[name]` getter: a global's value, or null if there is no such
    /// global.
    pub fn get_variable(story: *Story, name: []const u8) ?value_module.Value {
        assert(name.len > 0);
        const slot = story.program.global_by_name(name) orelse return null;
        assert(slot.to_int() < story.state.globals.len);
        assert(story.state.globals.len == story.program.globals.len);
        return story.state.globals[slot.to_int()];
    }

    /// ink's `variablesState[name]` setter. Only declared globals can be set; strings must
    /// already be references (see `set_variable_text`).
    pub fn set_variable(story: *Story, name: []const u8, value: value_module.Value) SetError!void {
        assert(name.len > 0);
        assert(value != .tag and value != .variable_pointer);
        const slot = story.program.global_by_name(name) orelse return error.VariableNotDeclared;
        if (story.callback_depth > 0) return error.Reentrant;
        try ops.set_global(story, slot, value);
        assert(story.state.globals[slot.to_int()] == std.meta.activeTag(value) or value == .list);
    }

    /// `set_variable` with a string value, copied into the heap.
    pub fn set_variable_text(story: *Story, name: []const u8, text: []const u8) SetError!void {
        assert(name.len > 0);
        if (story.program.global_by_name(name) == null) return error.VariableNotDeclared;
        const reference = story.state.allocate_string(@intCast(text.len), &.{}) catch
            return error.HeapLimit;
        @memcpy(story.state.strings.get(reference), text);
        assert(reference.is_heap());
        try story.set_variable(name, .{ .string = reference });
    }

    /// A container's path, as ink prints a divert target's path.
    pub fn path_of(story: *const Story, container: ContainerIndex) []const u8 {
        assert(container.to_int() < story.program.containers.len);
        const path = story.program.table().get(container).path;
        assert(!path.is_none());
        return story.program.strings.get(path);
    }

    /// A list's text as ink's InkList.ToString writes it.
    pub fn write_list(
        story: *Story,
        list: value_module.ListReference,
        writer: *std.Io.Writer,
    ) !void {
        assert(story.state.lists.check_reference(list));
        assert(story.state.lists.used <= story.state.lists.words.len);
        const lists: Lists = .{ .program = story.program, .slab = &story.state.lists };
        try lists.write(list, writer);
    }

    /// ink's RuntimeObjectsEqual (for saving only non-default globals): same type, then the
    /// same value; strings by text, lists by their items.
    pub fn values_equal(story: *Story, a: value_module.Value, b: value_module.Value) bool {
        assert(story.state.memory.len > 0);
        assert(@sizeOf(value_module.Value) == 12);
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .string => |text| std.mem.eql(u8, story.text_of(text), story.text_of(b.string)),
            .list => |list| list_items_equal(story, list, b.list),
            .null => true,
            .integer => |number| number == b.integer,
            .float => |number| number == b.float,
            .bool => |flag| flag == b.bool,
            .divert_target => |target| target == b.divert_target,
            .variable_pointer => |pointer| pointer.name == b.variable_pointer.name and
                pointer.context == b.variable_pointer.context,
            .tag => |text| std.mem.eql(u8, story.text_of(text), story.text_of(b.tag)),
        };
    }

    fn list_items_equal(
        story: *Story,
        a: value_module.ListReference,
        b: value_module.ListReference,
    ) bool {
        assert(story.state.lists.check_reference(a) and story.state.lists.check_reference(b));
        const items_a = story.state.lists.view(a).items;
        const items_b = story.state.lists.view(b).items;
        if (items_a.len != items_b.len) return false;
        for (items_a) |item| {
            if (std.mem.indexOfScalar(index.ListItemIndex, items_b, item) == null) return false;
        }
        assert(items_a.len == items_b.len);
        return true;
    }

    pub fn text_of(story: *const Story, reference: StringReference) []const u8 {
        assert(story.state.memory.len > 0);
        assert(reference != StringReference.none);
        return ops.strings_of(story).get(reference);
    }
};

const NameCounter = struct {
    count: u32 = 0,

    pub fn name(counter: *NameCounter, text: []const u8) !void {
        assert(counter.count < 1 << 16);
        assert(text.len > 0);
        counter.count += 1;
    }
};

const TagCounter = struct {
    count: u32 = 0,

    pub fn tag(counter: *TagCounter, text: []const u8) !void {
        assert(counter.count < std.math.maxInt(u32));
        assert(text.len < 1 << 20);
        counter.count += 1;
    }
};

pub const pop_call_stack = ops.pop_call_stack;
pub const try_exit_function_evaluation_from_game = ops.try_exit_function_evaluation_from_game;

comptime {
    _ = output_module;
}

const ProgramBuilder = @import("../core/program_builder.zig").ProgramBuilder;

test "a step budget stops a story that loops without output" {
    // Goal: P5.1; `steps_per_continue_max` is a hard limit. Method: a container that diverts
    // to itself forever; run reports the exhausted budget and cont returns StepLimit.
    const gpa = std.testing.allocator;
    var builder = try ProgramBuilder.init(gpa);
    defer builder.deinit();
    _ = try builder.begin_container(.{});
    try builder.add(.text, try builder.intern("start"));
    try builder.add(.newline, {});
    _ = try builder.begin_container(.{ .name = "spin" });
    try builder.add(.nop, {});
    try builder.add_divert("spin", .{ .kind = .plain, .conditional = false, .variable = false });
    try builder.end_container();
    try builder.end_container();
    var program = try builder.finish();
    defer program.deinit(gpa);
    var story: Story = undefined;
    try story.init(gpa, &program, .{ .steps_per_continue_max = 100 });
    defer story.deinit(gpa);
    var steps: u32 = 0;
    try std.testing.expectEqual(vm.RunResult.output, try vm.run(&story, 100, &steps));
    try std.testing.expectError(error.StepLimit, story.cont());
    var more: u32 = 0;
    try std.testing.expectEqual(vm.RunResult.budget_exhausted, try vm.run(&story, 50, &more));
    try std.testing.expectEqual(@as(u32, 50), more);
}

const Collected = struct {
    count: u32 = 0,
    last: [256]u8 = undefined,
    last_length: u32 = 0,

    fn handle(
        context: ?*anyopaque,
        message: []const u8,
        severity: state_module.Diagnostic.Severity,
    ) void {
        assert(message.len > 0);
        const collected: *Collected = @ptrCast(@alignCast(context.?));
        assert(severity == .@"error");
        collected.count += 1;
        collected.last_length = @intCast(@min(message.len, collected.last.len));
        @memcpy(collected.last[0..collected.last_length], message[0..collected.last_length]);
    }
};

test "an arithmetic fault is a story error, reported to the error handler" {
    // Goal: D18 and P5.10; `1 / 0` is a story error with ink's prefix, not a panic; without
    // a handler cont returns StoryError. Method: a two-line story dividing by zero.
    const gpa = std.testing.allocator;
    var builder = try ProgramBuilder.init(gpa);
    defer builder.deinit();
    _ = try builder.begin_container(.{});
    try builder.add(.eval_start, {});
    try builder.add(.integer, 1);
    try builder.add(.integer, 0);
    try builder.add(.divide, {});
    try builder.add(.eval_output, {});
    try builder.add(.eval_end, {});
    try builder.add(.newline, {});
    try builder.add(.done, {});
    try builder.end_container();
    var program = try builder.finish();
    defer program.deinit(gpa);
    var story: Story = undefined;
    try story.init(gpa, &program, .{});
    defer story.deinit(gpa);
    try std.testing.expectError(error.StoryError, story.cont());
    try std.testing.expect(story.state.has_error());
    try story.reset_state();
    var collected: Collected = .{};
    story.on_error = Collected.handle;
    story.on_error_context = &collected;
    _ = try story.cont();
    try std.testing.expectEqual(@as(u32, 1), collected.count);
    const message = collected.last[0..collected.last_length];
    try std.testing.expectEqualStrings("RUNTIME ERROR: (3): Attempted to divide by zero.", message);
    try std.testing.expect(!story.can_continue() and !story.state.has_error());
}

test "continue_maximally writes every line until the story stops" {
    // Goal: P5.5; ink's ContinueMaximally. Method: two lines, then the end.
    const gpa = std.testing.allocator;
    var builder = try ProgramBuilder.init(gpa);
    defer builder.deinit();
    _ = try builder.begin_container(.{});
    try builder.add(.text, try builder.intern("one"));
    try builder.add(.newline, {});
    try builder.add(.text, try builder.intern("two"));
    try builder.add(.newline, {});
    try builder.add(.end, {});
    try builder.end_container();
    var program = try builder.finish();
    defer program.deinit(gpa);
    var story: Story = undefined;
    try story.init(gpa, &program, .{});
    defer story.deinit(gpa);
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try story.continue_maximally(&writer);
    try std.testing.expectEqualStrings("one\ntwo\n", writer.buffered());
    try std.testing.expect(!story.can_continue());
}
