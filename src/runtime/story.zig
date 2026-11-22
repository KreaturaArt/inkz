//! A story: a borrowed program, one state, and ink's Continue loop around the VM, with
//! ink's host calls in snake_case. This is the public `inkz.Story`.
//!
//! Views (line text, choice text and tags, variable strings, flow names) are borrowed: valid
//! until the next mutating call. With runtime safety on, each view carries the story's
//! generation and asserts on use if a mutating call happened since. Callbacks take a
//! `context` pointer registered with them and come last in each parameter list.
//!
//! The host API is `Story`'s `pub` methods and the types above it (docs/RunningYourInk.md).
//! `Story`'s fields and the `pub fn`s after it, which take the story first, are the
//! runtime's internals, for its other files and the tests.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const profile = @import("../core/profile.zig");
const Allocator = std.mem.Allocator;
const Program = @import("../core/program.zig").Program;
const limits_module = @import("../core/limits.zig");
pub const Limits = limits_module.Limits;
/// A story's measured needs (`Story.usage`), for `fitted_limits`.
pub const Usage = limits_module.Usage;
pub const fitted_limits = limits_module.fitted;
const state_module = @import("state.zig");
const call_stack_module = @import("call_stack.zig");
const choices_module = @import("choices.zig");
const value_module = @import("value.zig");
const lookahead = @import("lookahead.zig");
const vm = @import("vm.zig");
const ops = @import("ops.zig");
const flows = @import("flows.zig");
const ink_json = @import("../core/ink_json.zig");
const story_paths = @import("story_paths.zig");
const evaluate = @import("evaluate.zig");
const save = @import("save.zig");
const load = @import("load.zig");
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
    /// A tag of the current line is longer than `Limits.tag_bytes_max` after cleaning.
    TagBytesLimit,
    SnapshotLimit,
    LookaheadLogLimit,
    /// A shuffle sequence (`{~a|b}`) has more than `ops.shuffle_elements_max` (1024) elements.
    ShuffleLimit,
    StepLimit,
    /// An external function the story calls has no binding (and no fallback); see
    /// `Story.missing_externals` (ink's ValidateExternalBindings, at the first `cont`).
    MissingExternalBinding,
    /// More globals changed in one `cont` than `observer_events_max`.
    ObserverQueueLimit,
    /// A mutating call from inside a callback (only evaluate_function may nest, and only in
    /// an external function).
    Reentrant,
    /// `cont` while `can_continue()` is false.
    CannotContinue,
    /// A bound external function returned an error.
    ExternalFunctionFailed,
    /// An earlier call failed in the middle of a step (a limit or host error), so the state
    /// is half done; `reset_state` or a successful `load_json` brings the story back.
    StoryFailed,
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
/// A value as the host sees it (`inkz.Value`).
pub const Value = HostValue;
pub const Severity = state_module.Diagnostic.Severity;

pub const Choice = struct {
    /// The position among the current choices (ink's choice.index).
    index: u32,
    text: []const u8,
    tags_count: u32,
};

pub const ChooseOptions = struct {
    /// Ends the current flow's call stack first (ink's default).
    reset_callstack: bool = true,
    /// Arguments for a knot with parameters.
    arguments: []const HostValue = &.{},
};

pub const BindOptions = struct {
    /// Whether calling it during the newline lookahead is harmless (ink's lookaheadSafe).
    lookahead_safe: bool = true,
};

/// An external function. It may call `evaluate_function` on `story`.
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

comptime {
    // The state carves the bindings as words (state.binding_words_each per binding).
    assert(@sizeOf(Binding) == limits_module.element_bytes.binding);
    assert(@alignOf(Binding) <= 8);
}

/// Receives each error and warning message at the end of `cont`, as ink's onError does.
pub const ErrorHandler = *const fn (
    context: ?*anyopaque,
    message: []const u8,
    severity: state_module.Diagnostic.Severity,
) void;

/// A variable observer (ink's VariableObserver): the global's name and new value.
pub const Observer = *const fn (context: ?*anyopaque, name: []const u8, value: HostValue) void;

/// ink's host events, each optional, each called with `context`, at ink's points:
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

const stamped = std.debug.runtime_safety;

/// A view into the story's memory, valid until the next mutating call on the story. With
/// runtime safety on, it remembers the story's generation and `get` asserts it is unchanged.
pub fn Borrowed(comptime T: type) type {
    return struct {
        value: T,
        stamp: Stamp,

        pub fn get(view: @This()) T {
            if (stamped) assert(view.stamp.owner.* == view.stamp.generation);
            return view.value;
        }
    };
}

const Stamp = if (stamped) struct { generation: u32, owner: *const u32 } else struct {};

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
    /// `callback_depth` while the innermost callback running is an external function, else 0.
    external_callback_depth: u32 = 0,
    /// The `continue_depth` that took the lookahead snapshot: only that level compares
    /// with it, restores it or discards it.
    lookahead_depth: u32 = 0,
    /// evaluate_function calls running now.
    evaluate_depth: u32 = 0,
    /// A limit or host error stopped a step half done: the story fails closed until
    /// `reset_state` or `load_json`.
    failed: bool = false,
    events: Events = .{},
    /// Bumped by every call that may change what a `Borrowed` view points at.
    generation: u32 = 0,
    /// Set by init_from_json, which owns the program.
    owned_program: ?*Program = null,

    pub const Options = struct {
        limits: Limits = .{},
        /// ink seeds from the clock; this runtime is deterministic by default.
        random_seed: i32 = 0,
        allow_external_function_fallbacks: bool = false,
        events: Events = .{},
        error_context: ?*anyopaque = null,
        /// ink's onError. Without it, cont returns error.StoryError when the story records
        /// an error or warning, and keeps them (see `error_count`).
        on_error: ?ErrorHandler = null,
    };

    /// A story on `program`, which must outlive it. `story` must not move afterwards.
    pub fn init(story: *Story, gpa: Allocator, program: *const Program, options: Options) !void {
        assert(program.containers.len > 0);
        story.* = .{ .program = program, .state = undefined, .bindings = &.{} };
        // One allocation: the bindings are carved from the state's block.
        try story.state.init(gpa, program, options.limits);
        errdefer story.state.deinit(gpa);
        const words = std.mem.sliceAsBytes(story.state.binding_words);
        story.bindings = std.mem.bytesAsSlice(Binding, words);
        assert(story.bindings.len == program.externals.len);
        @memset(story.bindings, .{});
        try story.reset_globals();
        assert(story.state.call_stack.depth() == 1);
        // Only now: the global declaration above runs without the host's handler and events.
        set_random_seed(story, options.random_seed);
        story.allow_external_function_fallbacks = options.allow_external_function_fallbacks;
        story.events = options.events;
        story.on_error = options.on_error;
        story.on_error_context = options.error_context;
    }

    /// A story that owns the program it loads from ink's JSON.
    pub fn init_from_json(story: *Story, gpa: Allocator, json: []const u8, options: Options) !void {
        assert(json.len > 0);
        const program = try gpa.create(Program);
        errdefer gpa.destroy(program);
        program.* = try ink_json.load(gpa, json);
        errdefer program.deinit(gpa);
        try story.init(gpa, program, options);
        story.owned_program = program;
    }

    // lint: allow recursion: the calls are Program.deinit and State.deinit.
    pub fn deinit(story: *Story, gpa: Allocator) void {
        assert(story.bindings.len == story.program.externals.len);
        const owned = story.owned_program;
        assert(owned == null or owned.? == story.program);
        const shape = State.shape_of(story.program);
        assert(story.state.memory.len == story.state.limits.bytes_total(shape));
        story.state.deinit(gpa);
        if (owned) |loaded| {
            loaded.deinit(gpa);
            gpa.destroy(loaded);
        }
        story.* = undefined;
    }

    /// The program the story runs (shared between stories on it).
    pub fn get_program(story: *const Story) *const Program {
        return story.program;
    }

    /// A view of `value`, which points into this story's memory.
    fn borrow(story: *const Story, comptime T: type, value: T) Borrowed(T) {
        if (!stamped) return .{ .value = value, .stamp = .{} };
        return .{
            .value = value,
            .stamp = .{ .generation = story.generation, .owner = &story.generation },
        };
    }

    /// What the story has needed since init: every buffer's peak. Play it well (every path,
    /// saves and loads), then size `Limits` with `fitted_limits(usage, 2)`.
    pub fn usage(story: *const Story) Usage {
        var result = story.state.usage();
        result.observers = story.observers_count;
        return result;
    }

    /// ink's ResetState: a fresh state, with the global declaration run again.
    pub fn reset_state(story: *Story) Error!void {
        try begin_mutation(story);
        story.state.reset();
        story.diverted_pointer = .null;
        story.failed = false;
        try story.reset_globals();
        assert(story.state.call_stack.depth() == 1);
    }

    /// ink's ResetErrors: drops the kept errors and warnings, so the story can continue.
    pub fn reset_errors(story: *Story) error{Reentrant}!void {
        try begin_mutation(story);
        story.state.reset_errors();
        assert(!story.state.has_error());
    }

    /// ink's SwitchFlow: makes flow `name` current, creating it at the root if it's new.
    pub fn switch_flow(story: *Story, name: []const u8) (Error || flows.Error)!void {
        assert(name.len > 0);
        try begin_mutation(story);
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
        assert(name.len > 0);
        try begin_mutation(story);
        try flows.remove_flow(&story.state, name);
    }

    /// ink's BindExternalFunctionGeneral. Names the story never calls are ignored.
    pub fn bind_external_function(
        story: *Story,
        name: []const u8,
        options: BindOptions,
        context: ?*anyopaque,
        function: ExternalFunction,
    ) error{AlreadyBound}!void {
        assert(name.len > 0);
        const external = story.program.external_by_name(name) orelse return;
        const binding = &story.bindings[external.to_int()];
        if (binding.function != null) return error.AlreadyBound;
        binding.* = .{
            .function = function,
            .context = context,
            .lookahead_safe = options.lookahead_safe,
        };
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

    fn validate_external_bindings(story: *Story) Error!void {
        assert(!story.has_validated_externals);
        assert(story.bindings.len == story.program.externals.len);
        story.has_validated_externals = true;
        var counter: NameCounter = .{};
        missing_externals(story, &counter) catch unreachable;
        if (counter.count > 0) return error.MissingExternalBinding;
    }

    /// ink's ResetGlobals: runs `global decl` from its start, then keeps the defaults.
    fn reset_globals(story: *Story) Error!void {
        const profile_zone = profile.begin(.reset_globals);
        defer profile_zone.end();
        assert(story.state.call_stack.depth() == 1);
        const declaration = story.program.global_declaration;
        if (!declaration.is_none()) {
            const original = vm.current_pointer(story);
            try choose_pointer(story, .start_of(declaration), false);
            _ = try story.continue_internal();
            story.state.call_stack.current_frame().pointer = original;
        }
        @memcpy(story.state.global_defaults, story.state.globals);
        assert(story.state.global_defaults.len == story.state.globals.len);
    }

    /// ink's canContinue.
    pub fn can_continue(story: *Story) bool {
        assert(story.state.call_stack.depth() > 0);
        if (story.failed) return false;
        return !vm.current_pointer(story).is_null() and !story.state.has_error();
    }

    /// ink's Continue: the next line, borrowed. Without an error handler, story errors stay
    /// in the story (`error_count`).
    pub fn cont(story: *Story) Error!Borrowed([]const u8) {
        const profile_zone = profile.begin(.cont);
        defer profile_zone.end();
        assert(story.state.call_stack.depth() > 0);
        try begin_mutation(story);
        if (story.failed) return error.StoryFailed;
        if (!story.can_continue()) return error.CannotContinue;
        return story.borrow([]const u8, try next_line(story));
    }

    /// `cont`, with the line copied into memory the caller owns.
    pub fn cont_alloc(story: *Story, gpa: Allocator) ![]u8 {
        return gpa.dupe(u8, (try story.cont()).get());
    }

    /// ink's ContinueMaximally: every line until the story can't continue, written to
    /// `writer`.
    pub fn continue_maximally(story: *Story, writer: *std.Io.Writer) !void {
        var lines: u32 = 0;
        while (story.can_continue()) : (lines += 1) {
            try writer.writeAll((try story.cont()).get());
        }
        assert(!story.can_continue());
    }

    pub fn continue_maximally_alloc(story: *Story, gpa: Allocator) ![]u8 {
        var writer: std.Io.Writer.Allocating = .init(gpa);
        errdefer writer.deinit();
        try story.continue_maximally(&writer.writer);
        return writer.toOwnedSlice();
    }

    /// The end of ink's ContinueInternal: each error, then each warning, to the handler,
    /// then ResetErrors.
    fn report_diagnostics(story: *Story) Error!void {
        const profile_zone = profile.begin(.report_diagnostics);
        defer profile_zone.end();
        const state = &story.state;
        if (!state.has_error() and !state.has_warning()) return;
        const handler = story.on_error orelse return error.StoryError;
        const lists = [_][]const state_module.Diagnostic{
            state.errors.slice(),
            state.warnings.slice(),
        };
        const severities = [_]Severity{ .@"error", .warning };
        for (lists, severities) |list, severity| {
            for (list) |diagnostic| {
                story.callback_depth += 1;
                defer story.callback_depth -= 1;
                handler(story.on_error_context, state.diagnostic_text(diagnostic), severity);
            }
        }
        if (state.diagnostics_dropped > 0) {
            var buffer: [128]u8 = undefined;
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
            if (steps == steps_max) return story.fail_step(error.StepLimit);
            const run_zone = profile.begin(.vm_run);
            const run = vm.run(story, steps_max - steps, &steps);
            run_zone.end();
            const result = run catch |err| switch (err) {
                error.StoryError => break,
                else => |other| return story.fail_step(other),
            };
            // A nested evaluate_function failed closed, and its external went on.
            if (story.failed) return story.fail_step(error.StoryFailed);
            if (result == .budget_exhausted) return story.fail_step(error.StepLimit);
            ends_in_newline = story.after_steps() catch |err| switch (err) {
                error.StoryError => break,
                else => |other| return story.fail_step(other),
            };
            if (ends_in_newline or !story.can_continue()) break;
        }
        if (ends_in_newline or !story.can_continue()) {
            if (owns_lookahead(story)) lookahead.restore(&story.state);
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
        if (story.continue_depth > 1) assert(!owns_lookahead(story));
        const length = try story.write_current_text();
        try story.report_diagnostics();
        // Last, since observers may run more ink.
        if (story.continue_depth == 1 and !story.batching_observers) story.notify_observers();
        return length;
    }

    /// A limit or host error in the middle of a step. In the newline lookahead
    /// of a host's `cont`, the state goes back to the end of the last line: it saves, and the
    /// next `cont` runs the same steps again. Anywhere else the step is half done, and the
    /// story fails closed (`failed`) instead of running on from there.
    fn fail_step(story: *Story, err: Error) Error {
        assert(err != error.StoryError);
        assert(story.continue_depth > 0);
        if (story.continue_depth > 1) {
            if (owns_lookahead(story)) lookahead.discard(&story.state);
            return err;
        }
        if (story.evaluate_depth == 0 and lookahead.active(&story.state)) {
            lookahead.restore(&story.state);
            return err;
        }
        if (lookahead.active(&story.state)) lookahead.discard(&story.state);
        story.failed = true;
        return err;
    }

    /// ink's ObserveVariable. Observers of a global are called in the order they were added.
    pub fn observe_variable(
        story: *Story,
        name: []const u8,
        context: ?*anyopaque,
        observer: Observer,
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
    }

    /// ink's NotifyObservers for the queued globals, with their current values.
    fn notify_observers(story: *Story) void {
        const profile_zone = profile.begin(.notify_observers);
        defer profile_zone.end();
        assert(story.continue_depth == 1);
        assert(!story.batching_observers);
        const queued = story.state.observer_events.count;
        var position: u32 = 0;
        while (position < queued) : (position += 1) {
            notify_global(story, story.state.observer_events.buffer[position]);
        }
        story.state.observer_events.clear();
    }

    /// The checks of ink's ContinueSingleStep after `vm.run` returns; returns whether the
    /// line is known to have ended.
    fn after_steps(story: *Story) Error!bool {
        const profile_zone = profile.begin(.after_steps);
        defer profile_zone.end();
        assert(story.state.call_stack.depth() > 0);
        const state = &story.state;
        const from_game = state.call_stack.current_frame().kind == .function_evaluation_from_game;
        if (!story.can_continue() and !from_game) {
            _ = try story.try_follow_default_invisible_choice();
        }
        if (state.output.in_string_evaluation()) return false;
        // A function evaluated from an external during an outer level's lookahead: that
        // snapshot isn't this level's, so this level runs to the function's end as one line.
        if (lookahead.active(state) and !owns_lookahead(story)) return false;
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
        story.lookahead_depth = story.continue_depth;
        assert(owns_lookahead(story));
    }

    const Change = enum { none, extended, newline_removed };

    /// ink's CalculateNewlineOutputStateChange, against the snapshot's text and tags.
    fn newline_change(story: *Story) Error!Change {
        assert(lookahead.active(&story.state));
        assert(story.snapshot_text_length <= story.state.line_bytes.len);
        const previous = story.snapshot_text_length;
        const length = try story.write_current_text();
        const text = story.line_text(length);
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

    /// ink's currentText: the output stream's text, cleaned.
    pub fn current_text(story: *Story) Error!Borrowed([]const u8) {
        assert(story.state.output.items.count <= story.state.output.items.capacity());
        const length = try story.write_current_text();
        return story.borrow([]const u8, story.line_text(length));
    }

    /// The current text, cleaned, in the text cache; returns its length.
    fn write_current_text(story: *Story) Error!u32 {
        const profile_zone = profile.begin(.clean_text);
        defer profile_zone.end();
        const state = &story.state;
        assert(state.line_bytes.len > 0);
        const strings = ops.strings_of(story);
        const text = try state.text_cache.update(&state.output, strings, state.strings.generation);
        if (builtin.mode == .debug) story.expect_full_clean(text);
        assert(text.len <= state.text_cache.text.len);
        state.peaks.line_bytes = @max(state.peaks.line_bytes, @as(u32, @intCast(text.len)));
        return @intCast(text.len);
    }

    /// Debug: the cache's text is what cleaning the whole output gives (cleaned into
    /// `line_bytes`, which is only scratch here).
    fn expect_full_clean(story: *Story, text: []const u8) void {
        assert(builtin.mode == .debug);
        assert(text.len <= story.state.text_cache.text.len);
        var writer: std.Io.Writer = .fixed(story.state.line_bytes);
        story.state.output.write_text(ops.strings_of(story), &writer) catch unreachable;
        assert(std.mem.eql(u8, writer.buffered(), text));
    }

    /// The current line's text after `write_current_text` returned `length`.
    fn line_text(story: *const Story, length: u32) []const u8 {
        assert(length <= story.state.text_cache.end);
        assert(story.state.text_cache.end <= story.state.text_cache.text.len);
        return story.state.text_cache.text[0..length];
    }

    fn current_tags_count(story: *Story) Error!u32 {
        assert(story.state.output.items.count <= story.state.output.items.buffer.len);
        var counter: TagCounter = .{};
        try story.collect_tags(&counter);
        return counter.count;
    }

    /// Calls `sink.tag(text)` for each tag of the current line; `text` is valid during the
    /// call.
    pub fn current_tags(story: *Story, sink: anytype) !void {
        assert(@typeInfo(@TypeOf(sink)) == .pointer);
        try story.collect_tags(sink);
    }

    /// The tags of the current line, each cleaned into the tag scratch and passed to `sink`.
    fn collect_tags(story: *Story, sink: anytype) !void {
        const state = &story.state;
        assert(state.tag_bytes.len == state.limits.tag_bytes_max);
        const longest = try state.output.collect_tags(ops.strings_of(story), state.tag_bytes, sink);
        assert(longest <= state.tag_bytes.len);
        state.peaks.tag_bytes = @max(state.peaks.tag_bytes, longest);
    }

    /// ink's end-of-content errors, when the story can't continue.
    fn check_end_of_content(story: *Story) void {
        assert(!story.can_continue());
        assert(story.state.call_stack.depth() > 0);
        const state = &story.state;
        if (state.call_stack.can_pop_thread()) {
            ops.fail(story, "Thread available to pop, threads should always be flat by the " ++
                "end of evaluation?", .{}) catch {};
        }
        if (state.choices.count() != 0 or state.did_safe_exit) return;
        const end = "unexpectedly reached end of content";
        if (state.call_stack.can_pop(.tunnel)) {
            ops.fail(story, end ++ ". Do you need a '->->' to return from a tunnel?", .{}) catch {};
        } else if (state.call_stack.can_pop(.function)) {
            ops.fail(story, end ++ ". Do you need a '~ return'?", .{}) catch {};
        } else if (!state.call_stack.can_pop(null)) {
            const text = "ran out of content. Do you need a '-> DONE' or '-> END'?";
            ops.fail(story, text, .{}) catch {};
        } else {
            ops.fail(story, end ++ " for unknown reason. Please debug compiler!", .{}) catch {};
        }
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
        try choose_pointer(story, choice.target, false);
        return true;
    }

    /// The choices shown to the player (ink's currentChoices): none while the story can
    /// continue, and never the invisible defaults.
    pub fn current_choices_count(story: *Story) u32 {
        if (story.failed) return 0;
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

    /// Choice `position`: `error.ChoiceLimit` past the choices (as in `choose_choice_index`).
    pub fn current_choice(story: *Story, position: u32) error{ChoiceLimit}!Borrowed(Choice) {
        if (position >= story.current_choices_count()) return error.ChoiceLimit;
        const record = visible_choice(story, position);
        return story.borrow(Choice, .{
            .index = position,
            .text = text_of(story, record.text),
            .tags_count = record.tags_count,
        });
    }

    /// Tag `tag` of choice `position`: `error.ChoiceLimit` past the choices (as in
    /// `choose_choice_index`), `error.TagLimit` past the choice's `tags_count`.
    pub fn current_choice_tag(
        story: *Story,
        position: u32,
        tag: u32,
    ) error{ ChoiceLimit, TagLimit }!Borrowed([]const u8) {
        if (position >= story.current_choices_count()) return error.ChoiceLimit;
        const record = visible_choice(story, position);
        if (tag >= record.tags_count) return error.TagLimit;
        const reference = story.state.choices.tags.slice()[record.tags_first + tag];
        return story.borrow([]const u8, text_of(story, reference));
    }

    /// ink's ChooseChoiceIndex.
    pub fn choose_choice_index(story: *Story, position: u32) Error!void {
        const profile_zone = profile.begin(.choose_choice);
        defer profile_zone.end();
        try begin_mutation(story);
        if (story.failed) return error.StoryFailed;
        if (position >= story.current_choices_count()) return error.ChoiceLimit;
        if (story.events.on_make_choice) |event| {
            const text = text_of(story, visible_choice(story, position).text);
            story.callback_depth += 1;
            defer story.callback_depth -= 1;
            event(story.events.context, text, position);
        }
        assert(!story.can_continue());
        const choice = visible_choice(story, position);
        story.state.choices.restore(&story.state.call_stack, choice) catch return error.FrameLimit;
        try choose_pointer(story, choice.target, true);
        assert(story.state.choices.count() == 0);
    }

    /// ink's ChoosePathString. Without `reset_callstack`, calling it inside a function is an
    /// error, as in ink.
    pub fn choose_path_string(story: *Story, path: []const u8, options: ChooseOptions) !void {
        try story_paths.choose_path_string(story, path, options.reset_callstack, options.arguments);
    }

    /// ink's `variablesState[name]` getter: a global's value, or null if there is no such
    /// global.
    pub fn get_variable(story: *Story, name: []const u8) ?Borrowed(Value) {
        assert(name.len > 0);
        const slot = story.program.global_by_name(name) orelse return null;
        assert(story.state.globals.len == story.program.globals.len);
        const value = story.state.globals[slot.to_int()];
        return story.borrow(Value, ops.host_value(story, value));
    }

    /// ink's `variablesState[name] = value`, type-checked as in ink: only declared globals;
    /// strings are copied into the story (a string from `get_variable` too).
    pub fn set_variable(story: *Story, name: []const u8, value: Value) SetError!void {
        assert(name.len > 0);
        if (value == .null) return error.VariableNotDeclared;
        const slot = story.program.global_by_name(name) orelse return error.VariableNotDeclared;
        try begin_mutation(story);
        var stored: [1]value_module.Value = undefined;
        try ops.values_of_host(story, &.{value}, &stored);
        try ops.set_global(story, slot, stored[0]);
        assert(story.state.globals[slot.to_int()] == std.meta.activeTag(stored[0]) or
            stored[0] == .list);
    }

    pub fn global_variable_count(story: *const Story) u32 {
        return @intCast(story.program.globals.len);
    }

    /// The name of global `position` (null past `global_variable_count`); owned by the
    /// program.
    pub fn global_variable_name(story: *const Story, position: u32) ?[]const u8 {
        if (position >= story.program.globals.len) return null;
        return story.program.strings.get(story.program.globals[position].name);
    }

    /// ink's EvaluateFunction: the function's text goes to `text_writer`; the result is
    /// borrowed. An external function may call it on the story it receives.
    pub fn evaluate_function(
        story: *Story,
        name: []const u8,
        arguments: []const Value,
        text_writer: *std.Io.Writer,
    ) evaluate.Error!Borrowed(Value) {
        const result = try evaluate.evaluate_function(story, name, arguments, text_writer);
        return story.borrow(Value, result);
    }

    pub fn current_flow_name(story: *Story) Borrowed([]const u8) {
        return story.borrow([]const u8, flows.current_name(&story.state));
    }

    /// Calls `sink.name(text)` for each flow but the default one (ink's aliveFlowNames).
    pub fn alive_flow_names(story: *Story, sink: anytype) !void {
        try flows.alive_flow_names(&story.state, sink);
    }

    /// ink's state.ToJson, streamed. A failed story (`error.StoryFailed`) is half done and
    /// doesn't save.
    pub fn to_json(story: *Story, writer: *std.Io.Writer) !void {
        if (story.callback_depth > 0) return error.Reentrant;
        if (story.failed) return error.StoryFailed;
        try save.to_json(story, writer);
    }

    /// ink's state.LoadJson; a save that doesn't load leaves the story unchanged.
    pub fn load_json(story: *Story, json: []const u8) load.Error!void {
        try load.load_json(story, json);
    }

    pub fn visit_count_at_path_string(story: *const Story, path: []const u8) u32 {
        return story_paths.visit_count_at_path_string(story, path);
    }

    /// Calls `sink.tag(text)` for each tag at the start of the knot or stitch at `path`.
    pub fn tags_for_content_at_path(story: *const Story, path: []const u8, sink: anytype) !void {
        try story_paths.tags_at_path(story, path, sink);
    }

    pub fn global_tags(story: *const Story, sink: anytype) !void {
        try story_paths.global_tags(story, sink);
    }

    pub fn has_error(story: *const Story) bool {
        return story.state.has_error();
    }

    pub fn has_warning(story: *const Story) bool {
        return story.state.has_warning();
    }

    /// The errors kept when there is no error handler (ink's currentErrors).
    pub fn error_count(story: *const Story) u32 {
        return story.state.errors.count;
    }

    pub fn warning_count(story: *const Story) u32 {
        return story.state.warnings.count;
    }

    /// Error `position`'s message: `error.OutOfRange` past `error_count`.
    pub fn write_error(story: *const Story, position: u32, writer: *std.Io.Writer) !void {
        if (position >= story.state.errors.count) return error.OutOfRange;
        try writer.writeAll(story.state.diagnostic_text(story.state.errors.slice()[position]));
    }

    /// Warning `position`'s message: `error.OutOfRange` past `warning_count`.
    pub fn write_warning(story: *const Story, position: u32, writer: *std.Io.Writer) !void {
        if (position >= story.state.warnings.count) return error.OutOfRange;
        try writer.writeAll(story.state.diagnostic_text(story.state.warnings.slice()[position]));
    }
};

// The runtime's internals on a story.

/// Makes every view handed out so far stale (`begin_mutation`, `evaluate_function`).
pub fn invalidate_views(story: *Story) void {
    story.generation +%= 1;
}

/// The start of a mutating call: the views handed out so far go stale, and the call is
/// refused from inside a callback.
pub fn begin_mutation(story: *Story) error{Reentrant}!void {
    invalidate_views(story);
    if (story.callback_depth > 0) return error.Reentrant;
}

/// Seeds RANDOM and shuffles (`Options.random_seed`): ink's storySeed, with
/// previousRandom reset. ink seeds from the clock; this runtime starts at 0.
pub fn set_random_seed(story: *Story, seed: i32) void {
    story.state.story_seed = seed;
    story.state.previous_random = 0;
    assert(story.state.story_seed == seed);
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

pub fn program_newline(story: *const Story) StringReference {
    assert(story.program.strings.get(story.program.newline).len == 1);
    assert(!story.program.newline.is_none());
    return .program(story.program.newline);
}

/// `cont` without the reentrancy check, for evaluate_function's loop.
pub fn next_line(story: *Story) Error![]const u8 {
    assert(story.can_continue());
    if (!story.has_validated_externals) try story.validate_external_bindings();
    story.state.did_safe_exit = false;
    story.state.output.clear();
    const length = try story.continue_internal();
    story.line_length = length;
    return story.line_text(length);
}

/// Whether any observer watches global `slot` (only those are queued).
pub fn is_observed(story: *const Story, slot: index.GlobalSlot) bool {
    for (story.state.observers[0..story.observers_count]) |record| {
        if (record.slot == slot) return true;
    }
    return false;
}

/// Calls the observers of global `slot` with its value now.
pub fn notify_global(story: *Story, slot: index.GlobalSlot) void {
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

/// Whether the lookahead snapshot is active and this Continue level took it.
pub fn owns_lookahead(story: *const Story) bool {
    if (lookahead.active(&story.state)) assert(story.lookahead_depth > 0);
    return lookahead.active(&story.state) and story.lookahead_depth == story.continue_depth;
}

/// Whether evaluate_function may run now: outside callbacks, or directly in an external
/// function. An observer, the error handler or an event runs in the middle of a `cont`
/// (or of another call) whose result evaluate_function would overwrite.
pub fn may_evaluate(story: *const Story) bool {
    assert(story.external_callback_depth <= story.callback_depth);
    return story.callback_depth == 0 or story.callback_depth == story.external_callback_depth;
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

pub fn visible_choice(story: *Story, position: u32) choices_module.Choice {
    assert(story.state.choices.count() > 0);
    assert(position < story.current_choices_count());
    var seen: u32 = 0;
    for (story.state.choices.records.slice()) |choice| {
        if (choice.invisible_default) continue;
        if (seen == position) return choice;
        seen += 1;
    }
    unreachable;
}

/// A container's path, as ink prints a divert target's path.
pub fn path_of(story: *const Story, container: ContainerIndex) []const u8 {
    assert(container.to_int() < story.program.containers.len);
    const path = story.program.container_info(container).path;
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

pub fn text_of(story: *const Story, reference: StringReference) []const u8 {
    assert(reference != StringReference.none);
    return ops.strings_of(story).get(reference);
}

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
        assert(text.len < 1 << 20);
        counter.count += 1;
    }
};

const ProgramBuilder = @import("../core/program_builder.zig").ProgramBuilder;

test "a step budget stops a story that loops without output" {
    // `steps_per_continue_max` is a hard limit: a container that diverts
    // to itself forever; run reports the exhausted budget and cont returns StepLimit.
    const gpa = std.testing.allocator;
    var builder = try ProgramBuilder.init(gpa);
    defer builder.deinit();
    _ = try builder.begin_container(.{});
    try builder.add(.text, try builder.intern("start"));
    try builder.add(.newline, {});
    _ = try builder.begin_container(.{ .name = "spin" });
    try builder.add(.nop, {});
    try builder.add_divert("spin", .{});
    try builder.end_container();
    try builder.end_container();
    var program = try builder.finish();
    defer program.deinit(gpa);
    var story: Story = undefined;
    try story.init(gpa, &program, .{ .limits = .{ .steps_per_continue_max = 100 } });
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
    // `1 / 0` is a story error with ink's prefix, not a panic; without
    // a handler cont returns StoryError. A two-line story dividing by zero.
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
    // Ink's ContinueMaximally: two lines, then the end.
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
