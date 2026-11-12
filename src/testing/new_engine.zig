//! The new runtime (`src/vm/`) behind the engine-neutral layer (plan P0.11, P5.1). It is
//! line-based like ink, so `continue_line` is one `cont()` and tags are per line.

const std = @import("std");
const assert = std.debug.assert;
const transcript = @import("transcript.zig");
const ink_json = @import("../core/ink_json.zig");
const Program = @import("../core/program.zig").Program;
const story_module = @import("../vm/story.zig");
const Story = story_module.Story;
const story_paths = @import("../vm/story_paths.zig");
const evaluate_module = @import("../vm/evaluate.zig");
const value_module = @import("../vm/value.zig");
const Severity = @import("../vm/state.zig").Diagnostic.Severity;

pub const NewEngine = struct {
    pub const tags_per_line = true;

    gpa: std.mem.Allocator,
    /// Heap-allocated so the story's borrowed pointer stays valid when the engine moves.
    program: *Program,
    story: *Story,
    /// The tags of the last line or choice, owned until the next call that returns tags.
    tags: std.ArrayList([]const u8) = .empty,
    tag_bytes: std.ArrayList(u8) = .empty,
    /// ink's message for the last exception, owned.
    exception: ?[]u8 = null,
    /// Text for the last `get` and the global names, owned until the next call.
    scratch: std.ArrayList(u8) = .empty,
    names: std.ArrayList([]const u8) = .empty,
    /// The text of the last `evaluate`, and its result's text.
    evaluated: std.ArrayList(u8) = .empty,
    evaluated_result: std.ArrayList(u8) = .empty,
    /// What `write_messages` writes; heap-allocated as the story's error handler context.
    messages: *Messages,
    bindings: std.ArrayList(*Bound) = .empty,

    pub fn open(gpa: std.mem.Allocator, json: []const u8) !NewEngine {
        assert(json.len > 0);
        const program = try gpa.create(Program);
        errdefer gpa.destroy(program);
        program.* = try ink_json.load(gpa, json);
        errdefer program.deinit(gpa);
        const story = try gpa.create(Story);
        errdefer gpa.destroy(story);
        try story.init(gpa, program, .{});
        errdefer story.deinit(gpa);
        const messages = try gpa.create(Messages);
        messages.* = .{ .gpa = gpa, .story = story };
        story.on_error = Messages.on_error;
        story.on_error_context = messages;
        const engine: NewEngine = .{
            .gpa = gpa,
            .program = program,
            .story = story,
            .messages = messages,
        };
        assert(engine.story.program == program);
        return engine;
    }

    pub fn deinit(engine: *NewEngine) void {
        assert(engine.story.state.memory.len > 0);
        assert(engine.story.program == engine.program);
        engine.tags.deinit(engine.gpa);
        engine.tag_bytes.deinit(engine.gpa);
        if (engine.exception) |text| engine.gpa.free(text);
        engine.scratch.deinit(engine.gpa);
        engine.names.deinit(engine.gpa);
        engine.evaluated.deinit(engine.gpa);
        engine.evaluated_result.deinit(engine.gpa);
        engine.messages.deinit(engine.gpa);
        engine.gpa.destroy(engine.messages);
        for (engine.bindings.items) |bound| bound.release(engine.gpa);
        engine.bindings.deinit(engine.gpa);
        engine.story.deinit(engine.gpa);
        engine.gpa.destroy(engine.story);
        engine.program.deinit(engine.gpa);
        engine.gpa.destroy(engine.program);
        engine.* = undefined;
    }

    pub fn can_continue(engine: *NewEngine) bool {
        assert(engine.story.program == engine.program);
        assert(engine.story.state.memory.len > 0);
        return engine.story.can_continue();
    }

    pub fn continue_line(engine: *NewEngine) !transcript.Line {
        assert(engine.can_continue());
        const text = engine.story.cont() catch |err| {
            if (err == error.MissingExternalBinding) try engine.missing_binding_exception();
            return err;
        };
        engine.clear_tags();
        try engine.story.current_tags(engine);
        try engine.finish_tags();
        assert(engine.tags.items.len < 1 << 16);
        return .{ .text = text, .tags = engine.tags.items };
    }

    /// The tag sink for `current_tags`: collects offsets, turned into slices at the end.
    pub fn tag(engine: *NewEngine, text: []const u8) !void {
        assert(engine.tags.items.len < 1 << 16);
        assert(text.len < 1 << 20);
        const start = engine.tag_bytes.items.len;
        try engine.tag_bytes.appendSlice(engine.gpa, text);
        // Stash the range; `finish_tags` turns it into a slice once the bytes stop moving.
        const range: []const u8 = @as([*]const u8, @ptrFromInt(start + 1))[0..text.len];
        try engine.tags.append(engine.gpa, range);
    }

    fn clear_tags(engine: *NewEngine) void {
        assert(engine.tag_bytes.items.len < 1 << 31);
        engine.tags.clearRetainingCapacity();
        engine.tag_bytes.clearRetainingCapacity();
        assert(engine.tags.items.len == 0);
    }

    fn finish_tags(engine: *NewEngine) !void {
        const bytes = engine.tag_bytes.items;
        for (engine.tags.items) |*range| {
            const start = @intFromPtr(range.ptr) - 1;
            assert(start + range.len <= bytes.len);
            range.* = bytes[start..][0..range.len];
        }
        assert(engine.tags.items.len < 1 << 16);
    }

    pub fn choices_count(engine: *NewEngine) u32 {
        assert(engine.story.program == engine.program);
        assert(engine.story.state.memory.len > 0);
        return engine.story.visible_choices_count();
    }

    pub fn choice(engine: *NewEngine, position: u32) transcript.Choice {
        assert(position < engine.choices_count());
        const record = engine.story.visible_choice(position);
        engine.clear_tags();
        const all = engine.story.state.choices.tags.slice();
        const references = all[record.tags_first..][0..record.tags_count];
        for (references) |reference| {
            engine.tag(engine.story.text_of(reference)) catch @panic("out of memory");
        }
        engine.finish_tags() catch unreachable;
        assert(engine.tags.items.len == record.tags_count);
        return .{ .text = engine.story.text_of(record.text), .tags = engine.tags.items };
    }

    pub fn choose(engine: *NewEngine, position: u32) !void {
        assert(engine.story.program == engine.program);
        assert(position < engine.choices_count());
        try engine.story.choose_choice_index(position);
    }

    pub fn seed(engine: *NewEngine, value: i32) void {
        assert(engine.story.state.memory.len > 0);
        engine.story.state.story_seed = value;
        engine.story.state.previous_random = 0;
        assert(engine.story.state.story_seed == value);
    }

    pub fn exception_message(engine: *NewEngine) ?[]const u8 {
        assert(engine.story.state.memory.len > 0);
        const message = engine.exception orelse return null;
        assert(message.len > 0);
        return message;
    }

    fn set_exception(engine: *NewEngine, comptime format: []const u8, arguments: anytype) !void {
        assert(format.len > 0);
        if (engine.exception) |old| engine.gpa.free(old);
        engine.exception = try std.fmt.allocPrint(engine.gpa, format, arguments);
        assert(engine.exception.?.len > 0);
    }

    pub fn set(engine: *NewEngine, name: []const u8, value: transcript.Value) !void {
        assert(value != .null);
        assert(name.len > 0);
        const story = engine.story;
        const result = switch (value) {
            .int => |number| story.set_variable(name, .{ .integer = @intCast(number) }),
            .float => |number| story.set_variable(name, .{ .float = @floatCast(number) }),
            .bool => |flag| story.set_variable(name, .{ .bool = flag }),
            .string => |text| story.set_variable_text(name, text),
            else => unreachable,
        };
        result catch |err| switch (err) {
            error.VariableNotDeclared => {
                try engine.set_exception("Cannot assign to a variable ({s}) that hasn't been " ++
                    "declared in the story", .{name});
                return err;
            },
            else => return err,
        };
    }

    pub fn get(engine: *NewEngine, name: []const u8) !transcript.Value {
        assert(name.len > 0);
        const value = engine.story.get_variable(name) orelse return .null;
        engine.scratch.clearRetainingCapacity();
        const result: transcript.Value = switch (value) {
            .null => .null,
            .integer => |number| .{ .int = number },
            .float => |number| float: {
                var buffer: [value_module.float_text_bytes_max]u8 = undefined;
                const text = value_module.format_float(number, &buffer);
                try engine.scratch.appendSlice(engine.gpa, text);
                break :float .{ .float_text = engine.scratch.items };
            },
            .bool => |flag| .{ .bool = flag },
            .string => |reference| .{ .string = engine.story.text_of(reference) },
            .list => |list| .{ .list = try engine.list_text(list) },
            .divert_target => |target| .{ .other = engine.story.path_of(target) },
            .variable_pointer, .tag => .{ .other = @tagName(value) },
        };
        assert(result != .string or result.string.len < 1 << 20);
        return result;
    }

    /// `evaluate`: the function's text and result, owned until the next call.
    pub fn evaluate(
        engine: *NewEngine,
        name: []const u8,
        arguments: []const transcript.Value,
    ) !struct { text: []const u8, result: transcript.Value } {
        assert(arguments.len <= 16);
        assert(name.len > 0);
        var hosts: [16]story_module.HostValue = undefined;
        for (arguments, 0..) |argument, position| hosts[position] = switch (argument) {
            .int => |number| .{ .integer = @intCast(number) },
            .float => |number| .{ .float = @floatCast(number) },
            .bool => |flag| .{ .bool = flag },
            .string => |text| .{ .string = text },
            else => .null,
        };
        engine.evaluated.clearRetainingCapacity();
        var text: std.Io.Writer.Allocating = .fromArrayList(engine.gpa, &engine.evaluated);
        const result = evaluate_module.evaluate_function(
            engine.story,
            name,
            hosts[0..arguments.len],
            &text.writer,
        );
        engine.evaluated = text.toArrayList();
        const value = result catch |err| {
            if (err == error.FunctionNotFound) try engine.set_exception(
                "Function doesn't exist: '{s}'",
                .{name},
            );
            return err;
        };
        return .{ .text = engine.evaluated.items, .result = try engine.transcript_value(value) };
    }

    fn transcript_value(engine: *NewEngine, value: story_module.HostValue) !transcript.Value {
        assert(engine.evaluated_result.items.len < 1 << 24);
        assert(engine.story.state.memory.len > 0);
        const owned = &engine.evaluated_result;
        owned.clearRetainingCapacity();
        return switch (value) {
            .null => .null,
            .integer => |number| .{ .int = number },
            .float => |number| float: {
                var buffer: [value_module.float_text_bytes_max]u8 = undefined;
                try owned.appendSlice(engine.gpa, value_module.format_float(number, &buffer));
                break :float .{ .float_text = owned.items };
            },
            .bool => |flag| .{ .bool = flag },
            .string => |text| .{ .string = text },
            .list => |list| list: {
                var writer: std.Io.Writer.Allocating = .fromArrayList(engine.gpa, owned);
                try engine.story.write_list(list, &writer.writer);
                owned.* = writer.toArrayList();
                break :list .{ .list = owned.items };
            },
            .divert_target => |target| .{ .other = engine.story.path_of(target) },
        };
    }

    pub fn observe(engine: *NewEngine, name: []const u8) !void {
        assert(name.len > 0);
        assert(engine.story.observers_count < engine.story.state.observers.len);
        try engine.story.observe_variable(name, Messages.observed, engine.messages);
    }

    fn write_host_value(
        engine: *NewEngine,
        writer: *std.Io.Writer,
        value: story_module.HostValue,
    ) !void {
        assert(@sizeOf(story_module.HostValue) > 0);
        assert(engine.story.state.memory.len > 0);
        try write_host_value_of(engine.gpa, engine.story, writer, value);
    }

    fn list_text(engine: *NewEngine, list: value_module.ListReference) ![]const u8 {
        assert(engine.story.state.memory.len > 0);
        assert(engine.scratch.items.len == 0);
        var writer: std.Io.Writer.Allocating = .fromArrayList(engine.gpa, &engine.scratch);
        try engine.story.write_list(list, &writer.writer);
        engine.scratch = writer.toArrayList();
        return engine.scratch.items;
    }

    /// Every global's name, sorted (for the `globals` action).
    pub fn global_names(engine: *NewEngine) ![]const []const u8 {
        assert(engine.names.items.len < 1 << 20);
        assert(engine.story.program.globals.len < 1 << 20);
        engine.names.clearRetainingCapacity();
        for (engine.story.program.globals) |global| {
            try engine.names.append(engine.gpa, engine.story.program.strings.get(global.name));
        }
        std.mem.sort([]const u8, engine.names.items, {}, less_than);
        return engine.names.items;
    }

    fn less_than(_: void, a: []const u8, b: []const u8) bool {
        assert(a.ptr != b.ptr or a.len == b.len);
        assert(a.len > 0 and b.len > 0);
        return std.mem.order(u8, a, b) == .lt;
    }

    pub fn choose_path(engine: *NewEngine, path: []const u8) !void {
        assert(path.len > 0);
        story_paths.choose_path_string(engine.story, path, true) catch |err| {
            if (err == error.PathNotFound) try engine.path_exception(path);
            return err;
        };
        assert(engine.story.state.choices.count() == 0);
    }

    fn path_exception(engine: *NewEngine, path: []const u8) !void {
        assert(engine.story.state.memory.len > 0);
        assert(path.len > 0);
        try engine.set_exception("Failed to find content at path '{s}', and no approximation " ++
            "of it was possible.", .{path});
    }

    pub fn visit_count(engine: *NewEngine, path: []const u8) !u32 {
        assert(engine.story.state.memory.len > 0);
        assert(path.len > 0);
        return story_paths.visit_count_at_path_string(engine.story, path);
    }

    pub fn global_tags(engine: *NewEngine) ![]const []const u8 {
        assert(engine.tags.items.len < 1 << 16);
        assert(engine.story.state.memory.len > 0);
        engine.clear_tags();
        try story_paths.global_tags(engine.story, engine);
        try engine.finish_tags();
        return engine.tags.items;
    }

    pub fn tags_at(engine: *NewEngine, path: []const u8) ![]const []const u8 {
        assert(engine.tags.items.len < 1 << 16);
        assert(path.len > 0);
        engine.clear_tags();
        story_paths.tags_at_path(engine.story, path, engine) catch |err| {
            if (err == error.PathNotFound) try engine.path_exception(path);
            return err;
        };
        try engine.finish_tags();
        return engine.tags.items;
    }

    /// ink's ValidateExternalBindings message.
    fn missing_binding_exception(engine: *NewEngine) !void {
        assert(!engine.story.has_validated_externals or engine.story.bindings.len > 0);
        var names: NameList = .{ .engine = engine };
        defer names.list.deinit(engine.gpa);
        try engine.story.missing_externals(&names);
        assert(names.count > 0);
        const suffix = if (engine.story.allow_external_function_fallbacks)
            ", and no fallback ink function found."
        else
            " (ink fallbacks disabled)";
        try engine.set_exception("ERROR: Missing function binding for external{s}: '{s}' {s}", .{
            if (names.count > 1) "s" else "", names.list.items, suffix,
        });
    }

    pub fn write_messages(engine: *NewEngine, writer: *std.Io.Writer) !void {
        assert(engine.story.state.memory.len > 0);
        assert(engine.messages.events.items.len < 1 << 24);
        const messages = engine.messages;
        try writer.writeAll(messages.events.items);
        try writer.writeAll(messages.errors.items);
        try writer.writeAll(messages.warnings.items);
        messages.events.clearRetainingCapacity();
        messages.errors.clearRetainingCapacity();
        messages.warnings.clearRetainingCapacity();
    }

    pub fn reset(engine: *NewEngine, argument: []const u8) !void {
        assert(argument.len == 0);
        try engine.story.reset_state();
        assert(engine.story.state.call_stack.depth() == 1);
    }

    pub fn fallbacks(engine: *NewEngine, argument: []const u8) !void {
        assert(engine.story.state.memory.len > 0);
        assert(argument.len > 0);
        engine.story.allow_external_function_fallbacks = std.mem.eql(u8, argument, "on");
    }

    pub fn unbind(engine: *NewEngine, name: []const u8) !void {
        assert(engine.story.state.memory.len > 0);
        assert(name.len > 0);
        try engine.story.unbind_external_function(name);
    }

    /// `bind <function> <behaviour> [lookahead_unsafe]`, as the harness binds.
    pub fn bind(engine: *NewEngine, argument: []const u8) !void {
        assert(engine.bindings.items.len < 1 << 16);
        assert(argument.len > 0);
        var words = std.mem.tokenizeScalar(u8, argument, ' ');
        const name = words.next() orelse return error.BadActionArgument;
        const behaviour_text = words.next() orelse return error.BadActionArgument;
        const behaviour = std.meta.stringToEnum(Behaviour, behaviour_text) orelse
            return error.BadActionArgument;
        const bound = try engine.gpa.create(Bound);
        errdefer engine.gpa.destroy(bound);
        const owned_name = try engine.gpa.dupe(u8, name);
        bound.* = .{ .engine = engine, .name = owned_name, .behaviour = behaviour };
        try engine.bindings.append(engine.gpa, bound);
        var rest = words.rest();
        if (behaviour == .@"return") rest = try bound.take_constant(engine.gpa, rest);
        if (behaviour == .increment_and_evaluate) {
            var function_words = std.mem.tokenizeScalar(u8, rest, ' ');
            bound.function = try engine.gpa.dupe(
                u8,
                function_words.next() orelse return error.BadActionArgument,
            );
            rest = function_words.rest();
        }
        const lookahead_safe = !std.mem.eql(u8, std.mem.trim(u8, rest, " "), "lookahead_unsafe");
        try engine.story.bind_external_function(name, Bound.call, bound, lookahead_safe);
    }
};

const Behaviour = enum { record, @"return", multiply, repeat, increment_and_evaluate };

/// One binding made by `bind`, the callback's context.
const Bound = struct {
    engine: *NewEngine,
    name: []u8,
    behaviour: Behaviour,
    constant: story_module.HostValue = .null,
    constant_text: []u8 = &.{},
    function: []u8 = &.{},
    result: std.ArrayList(u8) = .empty,

    fn release(bound: *Bound, gpa: std.mem.Allocator) void {
        assert(bound.result.items.len < 1 << 31);
        assert(bound.name.len > 0);
        gpa.free(bound.name);
        gpa.free(bound.constant_text);
        gpa.free(bound.function);
        bound.result.deinit(gpa);
        gpa.destroy(bound);
    }

    /// Parses `return`'s typed value; returns the rest of the argument.
    fn take_constant(bound: *Bound, gpa: std.mem.Allocator, rest: []const u8) ![]const u8 {
        assert(rest.len > 0);
        assert(bound.behaviour == .@"return");
        var buffer: [4096]u8 = undefined;
        const value = try transcript.parse_typed(rest, &buffer);
        bound.constant = switch (value) {
            .int => |number| .{ .integer = @intCast(number) },
            .float => |number| .{ .float = @floatCast(number) },
            .bool => |flag| .{ .bool = flag },
            .string => |text| string: {
                bound.constant_text = try gpa.dupe(u8, text);
                break :string .{ .string = bound.constant_text };
            },
            else => unreachable,
        };
        // A string constant is the last word; others are one word.
        if (value == .string) return "";
        var words = std.mem.tokenizeScalar(u8, rest, ' ');
        _ = words.next();
        _ = words.next();
        return words.rest();
    }

    fn call(
        context: ?*anyopaque,
        story: *Story,
        arguments: []const story_module.HostValue,
    ) anyerror!story_module.HostValue {
        assert(arguments.len <= story_module.external_arguments_max);
        const bound: *Bound = @ptrCast(@alignCast(context.?));
        assert(bound.engine.story == story);
        try bound.record(arguments);
        return switch (bound.behaviour) {
            .record => .null,
            .@"return" => bound.constant,
            .multiply => multiply(arguments),
            .repeat => bound.repeat(arguments),
            .increment_and_evaluate => bound.increment_and_evaluate(story, arguments),
        };
    }

    /// `external: name(args)`, rendered like the harness renders values.
    fn record(bound: *Bound, arguments: []const story_module.HostValue) !void {
        assert(bound.name.len > 0);
        const engine = bound.engine;
        const events = &engine.messages.events;
        var writer: std.Io.Writer.Allocating = .fromArrayList(engine.gpa, events);
        defer events.* = writer.toArrayList();
        try writer.writer.print("external: {s}(", .{bound.name});
        for (arguments, 0..) |argument, position| {
            if (position > 0) try writer.writer.writeAll(", ");
            try engine.write_host_value(&writer.writer, argument);
        }
        try writer.writer.writeAll(")\n");
        assert(arguments.len <= story_module.external_arguments_max);
    }

    /// `EvaluateFunction(<ink function>, x + 1)` from inside the external, discarding the
    /// function's text as ink's overload without `out` text does.
    fn increment_and_evaluate(
        bound: *Bound,
        story: *Story,
        arguments: []const story_module.HostValue,
    ) !story_module.HostValue {
        assert(bound.function.len > 0);
        assert(arguments.len == 1 and arguments[0] == .integer);
        var discarding: std.Io.Writer.Discarding = .init(&.{});
        const argument: story_module.HostValue = .{ .integer = arguments[0].integer +% 1 };
        return evaluate_module.evaluate_function(
            story,
            bound.function,
            &.{argument},
            &discarding.writer,
        );
    }

    fn multiply(arguments: []const story_module.HostValue) story_module.HostValue {
        assert(arguments.len <= story_module.external_arguments_max);
        assert(arguments.len > 0);
        var any_float = false;
        for (arguments) |argument| any_float = any_float or argument == .float;
        if (any_float) {
            var product: f32 = 1;
            for (arguments) |argument| product *= switch (argument) {
                .float => |number| number,
                .integer => |number| @floatFromInt(number),
                else => 0,
            };
            return .{ .float = product };
        }
        var whole: i32 = 1;
        for (arguments) |argument| whole *%= if (argument == .integer) argument.integer else 0;
        return .{ .integer = whole };
    }

    fn repeat(bound: *Bound, arguments: []const story_module.HostValue) !story_module.HostValue {
        assert(arguments[0] == .integer and arguments[1] == .string);
        assert(arguments.len == 2);
        const gpa = bound.engine.gpa;
        bound.result.clearRetainingCapacity();
        const times: usize = @intCast(@max(arguments[0].integer, 0));
        for (0..times) |_| try bound.result.appendSlice(gpa, arguments[1].string);
        return .{ .string = bound.result.items };
    }
};

const NameList = struct {
    engine: *NewEngine,
    list: std.ArrayList(u8) = .empty,
    count: u32 = 0,

    pub fn name(names: *NameList, text: []const u8) !void {
        assert(names.count < 1 << 16);
        assert(text.len > 0);
        if (names.count > 0) try names.list.appendSlice(names.engine.gpa, "', '");
        try names.list.appendSlice(names.engine.gpa, text);
        names.count += 1;
    }
};

/// Host events since the last action (`external: ...` lines) and the story's error and
/// warning messages, as the harness collects them.
const Messages = struct {
    gpa: std.mem.Allocator,
    story: *Story,
    events: std.ArrayList(u8) = .empty,
    errors: std.ArrayList(u8) = .empty,
    warnings: std.ArrayList(u8) = .empty,

    fn deinit(messages: *Messages, gpa: std.mem.Allocator) void {
        assert(messages.events.items.len < 1 << 31);
        assert(messages.errors.items.len < 1 << 31);
        messages.events.deinit(gpa);
        messages.errors.deinit(gpa);
        messages.warnings.deinit(gpa);
    }

    /// `observed: name = value`, as the harness's observer records it.
    fn observed(context: ?*anyopaque, name: []const u8, value: story_module.HostValue) void {
        const messages: *Messages = @ptrCast(@alignCast(context.?));
        assert(messages.events.items.len < 1 << 24);
        assert(name.len > 0);
        var writer: std.Io.Writer.Allocating = .fromArrayList(messages.gpa, &messages.events);
        defer messages.events = writer.toArrayList();
        writer.writer.print("observed: {s} = ", .{name}) catch return;
        write_host_value_of(messages.gpa, messages.story, &writer.writer, value) catch return;
        writer.writer.writeByte('\n') catch return;
    }

    fn on_error(context: ?*anyopaque, message: []const u8, severity: Severity) void {
        assert(message.len < 1 << 20);
        const messages: *Messages = @ptrCast(@alignCast(context.?));
        assert(message.len > 0);
        const list = if (severity == .@"error") &messages.errors else &messages.warnings;
        var writer: std.Io.Writer.Allocating = .fromArrayList(messages.gpa, list);
        defer list.* = writer.toArrayList();
        writer.writer.writeAll(if (severity == .@"error") "error: " else "warning: ") catch return;
        transcript.write_json_string(&writer.writer, message) catch return;
        writer.writer.writeByte('\n') catch return;
    }
};

/// A host value as the harness renders one.
fn write_host_value_of(
    gpa: std.mem.Allocator,
    story: *Story,
    writer: *std.Io.Writer,
    value: story_module.HostValue,
) !void {
    assert(story.state.memory.len > 0);
    assert(@sizeOf(story_module.HostValue) > 0);
    switch (value) {
        .null => try writer.writeAll("null"),
        .integer => |number| try writer.print("int {d}", .{number}),
        .float => |number| {
            var buffer: [value_module.float_text_bytes_max]u8 = undefined;
            try writer.print("float {s}", .{value_module.format_float(number, &buffer)});
        },
        .bool => |flag| try writer.writeAll(if (flag) "bool true" else "bool false"),
        .string => |text| {
            try writer.writeAll("string ");
            try transcript.write_json_string(writer, text);
        },
        .list => |list| {
            var text: std.Io.Writer.Allocating = .init(gpa);
            defer text.deinit();
            try story.write_list(list, &text.writer);
            try writer.writeAll("list ");
            try transcript.write_json_string(writer, text.written());
        },
        .divert_target => |target| {
            try writer.writeAll("other ");
            try transcript.write_json_string(writer, story.path_of(target));
        },
    }
}
