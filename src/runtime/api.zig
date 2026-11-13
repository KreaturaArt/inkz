//! The public API of the runtime (plan §4.7, P6.3, D5, D8, D22). It wraps the runtime's
//! Story with ink's host calls, in snake_case.
//!
//! Views (line text, choice text and tags, variable strings, flow names) are borrowed: valid
//! until the next mutating call. In Debug, each view carries the story's generation and
//! asserts on use if a mutating call happened since. Callbacks take a `context` pointer
//! registered with them (D22) and come last in each parameter list.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Program = @import("../core/program.zig").Program;
const ink_json = @import("../core/ink_json.zig");
const limits_module = @import("../core/limits.zig");
const story_module = @import("story.zig");
const story_paths = @import("story_paths.zig");
const evaluate = @import("evaluate.zig");
const save = @import("save.zig");
const load = @import("load.zig");
const flows = @import("flows.zig");
const messages = @import("messages.zig");
const state_module = @import("state.zig");

pub const Limits = limits_module.Limits;
/// A story's measured needs (`Story.usage`), for `fitted_limits` (P10.2).
pub const Usage = limits_module.Usage;
pub const fitted_limits = limits_module.fitted;
/// A value as the host sees it; strings are borrowed slices.
pub const Value = story_module.HostValue;
pub const Events = story_module.Events;
pub const ErrorHandler = story_module.ErrorHandler;
pub const Observer = story_module.Observer;
pub const ExternalFunction = story_module.ExternalFunction;
pub const Severity = state_module.Diagnostic.Severity;
pub const Error = story_module.Error;
pub const SetError = story_module.SetError;

const stamped = std.debug.runtime_safety;

/// A view into the story's memory, valid until the next mutating call.
pub fn Borrowed(comptime T: type) type {
    return struct {
        value: T,
        stamp: Stamp,

        /// The view's value; in Debug, asserts that no mutating call happened since.
        pub fn get(view: @This()) T {
            assert(@sizeOf(T) > 0);
            assert(@sizeOf(Stamp) >= 0);
            view.stamp.check();
            return view.value;
        }
    };
}

const Stamp = if (stamped) struct {
    generation: u32,
    owner: *const u32,

    fn check(stamp: Stamp) void {
        assert(@sizeOf(Stamp) >= 0);
        assert(stamp.owner.* == stamp.generation);
    }
} else struct {
    fn check(stamp: Stamp) void {
        assert(@sizeOf(Stamp) >= 0);
        assert(@sizeOf(Stamp) <= 16);
        _ = stamp;
    }
};

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
    arguments: []const Value = &.{},
};

pub const BindOptions = struct {
    /// Whether calling it during the newline lookahead is harmless (ink's lookaheadSafe).
    lookahead_safe: bool = true,
};

pub const Story = struct {
    core: story_module.Story,
    /// Set by init_from_json, which owns the program.
    owned_program: ?*Program = null,
    /// Bumped by every mutating call; views remember it.
    generation: u32 = 0,

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
        story.* = .{ .core = undefined };
        try story.core.init(gpa, program, options.limits);
        story.apply(options);
        assert(story.core.program == program);
    }

    /// A story that owns the program it loads from ink's JSON.
    pub fn init_from_json(story: *Story, gpa: Allocator, json: []const u8, options: Options) !void {
        // `story` is usually undefined here, so only the arguments are checked.
        assert(json.len > 0);
        assert(json.len < std.math.maxInt(u32));
        const program = try gpa.create(Program);
        errdefer gpa.destroy(program);
        program.* = try ink_json.load(gpa, json);
        errdefer program.deinit(gpa);
        try story.init(gpa, program, options);
        story.owned_program = program;
    }

    fn apply(story: *Story, options: Options) void {
        assert(story.generation == 0);
        assert(story.core.state.memory.len > 0);
        story.core.set_random_seed(options.random_seed);
        story.core.allow_external_function_fallbacks = options.allow_external_function_fallbacks;
        story.core.events = options.events;
        story.core.on_error = options.on_error;
        story.core.on_error_context = options.error_context;
    }

    // lint: allow recursion: the calls are Program.deinit and the core Story's deinit.
    pub fn deinit(story: *Story, gpa: Allocator) void {
        assert(story.core.state.memory.len > 0);
        const owned = story.owned_program;
        assert(owned == null or owned.? == story.core.program);
        story.core.deinit(gpa);
        if (owned) |loaded| {
            loaded.deinit(gpa);
            gpa.destroy(loaded);
        }
        story.* = undefined;
    }

    fn mutate(story: *Story) void {
        assert(story.core.program.containers.len > 0);
        assert(story.core.state.memory.len > 0);
        story.generation +%= 1;
    }

    fn view(story: *const Story, comptime T: type, value: T) Borrowed(T) {
        assert(story.core.program.containers.len > 0);
        assert(story.core.state.memory.len > 0);
        const stamp: Stamp = if (stamped)
            .{ .generation = story.generation, .owner = &story.generation }
        else
            .{};
        return .{ .value = value, .stamp = stamp };
    }

    /// The program the story runs (shared between stories on it).
    pub fn get_program(story: *const Story) *const Program {
        assert(story.core.state.memory.len > 0);
        assert(story.core.program.containers.len > 0);
        return story.core.program;
    }

    // Continuing.

    pub fn can_continue(story: *Story) bool {
        assert(story.core.program.containers.len > 0);
        assert(story.core.state.memory.len > 0);
        return story.core.can_continue();
    }

    /// ink's Continue: the next line, borrowed.
    pub fn cont(story: *Story) Error!Borrowed([]const u8) {
        assert(story.core.state.memory.len > 0);
        assert(story.core.program.containers.len > 0);
        story.mutate();
        const line = try story.core.cont();
        return story.view([]const u8, line);
    }

    /// `cont`, with the line copied into memory the caller owns.
    pub fn cont_alloc(story: *Story, gpa: Allocator) ![]u8 {
        assert(story.core.state.memory.len > 0);
        assert(story.core.program.containers.len > 0);
        const line = try story.cont();
        return gpa.dupe(u8, line.get());
    }

    /// ink's ContinueMaximally, into `writer`.
    pub fn continue_maximally(story: *Story, writer: *std.Io.Writer) !void {
        assert(story.core.state.memory.len > 0);
        story.mutate();
        try story.core.continue_maximally(writer);
        assert(!story.core.can_continue());
    }

    pub fn continue_maximally_alloc(story: *Story, gpa: Allocator) ![]u8 {
        assert(story.core.state.memory.len > 0);
        assert(story.core.program.containers.len > 0);
        var writer: std.Io.Writer.Allocating = .init(gpa);
        errdefer writer.deinit();
        try story.continue_maximally(&writer.writer);
        return writer.toOwnedSlice();
    }

    /// ink's currentText.
    pub fn current_text(story: *Story) Error!Borrowed([]const u8) {
        assert(story.core.state.memory.len > 0);
        assert(story.core.program.containers.len > 0);
        const text = try story.core.current_text();
        return story.view([]const u8, text);
    }

    /// Calls `sink.tag(text)` for each tag of the current line; `text` is valid during the
    /// call.
    pub fn current_tags(story: *Story, sink: anytype) !void {
        assert(story.core.state.memory.len > 0);
        assert(@typeInfo(@TypeOf(sink)) == .pointer);
        try story.core.current_tags(sink);
    }

    // Choices.

    pub fn current_choices_count(story: *Story) u32 {
        assert(story.core.program.containers.len > 0);
        assert(story.core.state.memory.len > 0);
        return story.core.visible_choices_count();
    }

    pub fn current_choice(story: *Story, position: u32) Borrowed(Choice) {
        assert(story.core.state.memory.len > 0);
        assert(story.core.program.containers.len > 0);
        const record = story.core.visible_choice(position);
        const choice: Choice = .{
            .index = position,
            .text = story.core.text_of(record.text),
            .tags_count = record.tags_count,
        };
        return story.view(Choice, choice);
    }

    pub fn current_choice_tag(story: *Story, position: u32, tag: u32) Borrowed([]const u8) {
        assert(story.core.state.memory.len > 0);
        const record = story.core.visible_choice(position);
        assert(tag < record.tags_count);
        const reference = story.core.state.choices.tags.slice()[record.tags_first + tag];
        return story.view([]const u8, story.core.text_of(reference));
    }

    /// ink's ChooseChoiceIndex.
    pub fn choose_choice_index(story: *Story, position: u32) Error!void {
        assert(story.core.state.memory.len > 0);
        assert(story.core.program.containers.len > 0);
        if (position >= story.core.visible_choices_count()) return error.ChoiceLimit;
        story.mutate();
        try story.core.choose_choice_index(position);
    }

    /// ink's ChoosePathString. Without `reset_callstack`, calling it inside a function is an
    /// error, as in ink.
    pub fn choose_path_string(story: *Story, path: []const u8, options: ChooseOptions) !void {
        assert(story.core.state.memory.len > 0);
        assert(path.len > 0);
        story.mutate();
        try story_paths.choose_path_string(
            &story.core,
            path,
            options.reset_callstack,
            options.arguments,
        );
    }

    // Variables.

    pub fn get_variable(story: *Story, name: []const u8) ?Borrowed(Value) {
        assert(story.core.state.memory.len > 0);
        assert(story.core.program.containers.len > 0);
        const value = story.core.get_variable(name) orelse return null;
        return story.view(Value, @import("ops.zig").host_value(&story.core, value));
    }

    /// ink's `variablesState[name] = value`, type-checked as in ink: only declared globals;
    /// strings are copied into the story.
    pub fn set_variable(story: *Story, name: []const u8, value: Value) SetError!void {
        assert(story.core.state.memory.len > 0);
        assert(name.len > 0);
        story.mutate();
        switch (value) {
            .string => |text| return story.core.set_variable_text(name, text),
            .null => return error.VariableNotDeclared,
            else => {},
        }
        const converted = @import("ops.zig").value_of_host(&story.core, value) catch |err|
            return err;
        try story.core.set_variable(name, converted);
    }

    pub fn global_variable_count(story: *const Story) u32 {
        assert(story.core.state.memory.len > 0);
        assert(story.core.program.globals.len < std.math.maxInt(u32));
        return @intCast(story.core.program.globals.len);
    }

    /// The name of global `position`; owned by the program.
    pub fn global_variable_name(story: *const Story, position: u32) []const u8 {
        assert(story.core.state.memory.len > 0);
        assert(position < story.core.program.globals.len);
        return story.core.program.strings.get(story.core.program.globals[position].name);
    }

    /// ink's ObserveVariable.
    pub fn observe_variable(
        story: *Story,
        name: []const u8,
        context: ?*anyopaque,
        observer: Observer,
    ) error{ VariableNotDeclared, ObserverLimit }!void {
        assert(story.core.state.memory.len > 0);
        assert(name.len > 0);
        try story.core.observe_variable(name, observer, context);
    }

    /// ink's BindExternalFunctionGeneral.
    pub fn bind_external_function(
        story: *Story,
        name: []const u8,
        options: BindOptions,
        context: ?*anyopaque,
        function: ExternalFunction,
    ) error{AlreadyBound}!void {
        assert(story.core.state.memory.len > 0);
        assert(name.len > 0);
        try story.core.bind_external_function(name, function, context, options.lookahead_safe);
    }

    pub fn unbind_external_function(story: *Story, name: []const u8) error{NotBound}!void {
        assert(story.core.state.memory.len > 0);
        assert(name.len > 0);
        try story.core.unbind_external_function(name);
    }

    /// ink's EvaluateFunction: the function's text goes to `text_writer`; the result is
    /// borrowed.
    pub fn evaluate_function(
        story: *Story,
        name: []const u8,
        arguments: []const Value,
        text_writer: *std.Io.Writer,
    ) evaluate.Error!Borrowed(Value) {
        assert(story.core.state.memory.len > 0);
        assert(name.len > 0);
        story.mutate();
        const result = try evaluate.evaluate_function(&story.core, name, arguments, text_writer);
        return story.view(Value, result);
    }

    // Flows.

    pub fn switch_flow(story: *Story, name: []const u8) !void {
        assert(story.core.state.memory.len > 0);
        assert(story.core.program.containers.len > 0);
        story.mutate();
        try story.core.switch_flow(name);
    }

    pub fn switch_to_default_flow(story: *Story) !void {
        assert(story.core.state.memory.len > 0);
        assert(story.core.program.containers.len > 0);
        story.mutate();
        try story.core.switch_to_default_flow();
    }

    pub fn remove_flow(story: *Story, name: []const u8) !void {
        assert(story.core.state.memory.len > 0);
        assert(story.core.program.containers.len > 0);
        story.mutate();
        try story.core.remove_flow(name);
    }

    pub fn current_flow_name(story: *Story) Borrowed([]const u8) {
        assert(story.core.state.memory.len > 0);
        assert(story.core.program.containers.len > 0);
        return story.view([]const u8, flows.current_name(&story.core.state));
    }

    /// Calls `sink.name(text)` for each flow but the default one (ink's aliveFlowNames).
    pub fn alive_flow_names(story: *Story, sink: anytype) !void {
        assert(story.core.state.memory.len > 0);
        assert(@typeInfo(@TypeOf(sink)) == .pointer);
        try flows.alive_flow_names(&story.core.state, sink);
    }

    // State.

    /// ink's state.ToJson, streamed.
    /// What the story has needed since init: every buffer's peak (P10.2). Play it well
    /// (every path, saves and loads), then size `Limits` with `fitted_limits(usage, 2)`.
    pub fn usage(story: *const Story) Usage {
        assert(story.core.state.memory.len > 0);
        assert(story.core.program.containers.len > 0);
        return story.core.usage();
    }

    /// A failed story (`error.StoryFailed`) is half done and doesn't save.
    pub fn to_json(story: *Story, writer: *std.Io.Writer) !void {
        if (story.core.failed) return error.StoryFailed;
        assert(story.core.state.memory.len > 0);
        assert(story.core.callback_depth == 0);
        try save.to_json(&story.core, writer);
    }

    /// ink's state.LoadJson; a save that doesn't load leaves the story unchanged.
    pub fn load_json(story: *Story, json: []const u8) load.Error!void {
        assert(story.core.state.memory.len > 0);
        assert(story.core.program.containers.len > 0);
        story.mutate();
        try load.load_json(&story.core, json);
    }

    /// ink's ResetState.
    pub fn reset_state(story: *Story) Error!void {
        assert(story.core.state.memory.len > 0);
        assert(story.core.program.containers.len > 0);
        story.mutate();
        try story.core.reset_state();
    }

    // Inspection.

    pub fn visit_count_at_path_string(story: *const Story, path: []const u8) u32 {
        assert(story.core.state.memory.len > 0);
        assert(path.len > 0);
        return story_paths.visit_count_at_path_string(&story.core, path);
    }

    /// Calls `sink.tag(text)` for each tag at the start of the knot or stitch at `path`.
    pub fn tags_for_content_at_path(story: *const Story, path: []const u8, sink: anytype) !void {
        assert(story.core.state.memory.len > 0);
        assert(path.len > 0);
        try story_paths.tags_at_path(&story.core, path, sink);
    }

    pub fn global_tags(story: *const Story, sink: anytype) !void {
        assert(story.core.state.memory.len > 0);
        assert(@typeInfo(@TypeOf(sink)) == .pointer);
        try story_paths.global_tags(&story.core, sink);
    }

    pub fn has_error(story: *const Story) bool {
        assert(story.core.program.containers.len > 0);
        assert(story.core.state.memory.len > 0);
        return story.core.state.has_error();
    }

    pub fn has_warning(story: *const Story) bool {
        assert(story.core.program.containers.len > 0);
        assert(story.core.state.memory.len > 0);
        return story.core.state.has_warning();
    }

    /// The errors kept when there is no error handler (ink's currentErrors).
    pub fn error_count(story: *const Story) u32 {
        assert(story.core.state.memory.len > 0);
        assert(story.core.state.errors.count <= story.core.state.errors.capacity());
        return story.core.state.errors.count;
    }

    pub fn warning_count(story: *const Story) u32 {
        assert(story.core.state.memory.len > 0);
        assert(story.core.state.warnings.count <= story.core.state.warnings.capacity());
        return story.core.state.warnings.count;
    }

    pub fn write_error(story: *const Story, position: u32, writer: *std.Io.Writer) !void {
        assert(story.core.state.memory.len > 0);
        assert(position < story.core.state.errors.count);
        try messages.write(&story.core, story.core.state.errors.slice()[position], writer);
    }

    pub fn write_warning(story: *const Story, position: u32, writer: *std.Io.Writer) !void {
        assert(story.core.state.memory.len > 0);
        assert(position < story.core.state.warnings.count);
        try messages.write(&story.core, story.core.state.warnings.slice()[position], writer);
    }

    /// ink's ResetErrors: drops the kept errors and warnings, so the story can continue.
    pub fn reset_errors(story: *Story) void {
        assert(story.core.state.memory.len > 0);
        assert(story.core.program.containers.len > 0);
        story.mutate();
        story.core.state.reset_errors();
    }
};
