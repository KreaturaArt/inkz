//! Replays transcript actions (`transcript.zig`) on the runtime and writes what the C#
//! reference harness writes: lines, choices and values, ink's exception messages, host
//! events, observed variables and the story's errors and warnings. The runtime is
//! line-based like ink, so `continue` is one `cont()` and tags are per line.

const std = @import("std");
const assert = std.debug.assert;
const transcript = @import("transcript.zig");
const write_json_string = transcript.write_json_string;
const ink_json = @import("../core/ink_json.zig");
const Program = @import("../core/program.zig").Program;
const DotnetRandom = @import("../core/dotnet_random.zig").DotnetRandom;
const story_module = @import("../runtime/story.zig");
const Story = story_module.Story;
const HostValue = story_module.HostValue;
const ops = @import("../runtime/ops.zig");
const story_paths = @import("../runtime/story_paths.zig");
const evaluate_module = @import("../runtime/evaluate.zig");
const save_module = @import("../runtime/save.zig");
const load_module = @import("../runtime/load.zig");
const value_module = @import("../runtime/value.zig");
const Severity = @import("../runtime/state.zig").Diagnostic.Severity;

/// A story and what the harness records about it. It must not move after `init`: the story
/// borrows `program`, and the story's callbacks get the harness as their context.
pub const Harness = struct {
    gpa: std.mem.Allocator,
    program: Program,
    story: Story,
    /// The tags of the last line or choice: their bytes, and where each one ends.
    tag_bytes: std.ArrayList(u8) = .empty,
    tag_ends: std.ArrayList(u32) = .empty,
    /// ink's message for the exception that stopped the replay; empty when the error's name
    /// says it.
    exception: []u8 = &.{},
    /// The last save, for `load` and `load_fresh`.
    saved: std.ArrayList(u8) = .empty,
    /// Since the last action: host events (`external:`, `observed:`, `event:` lines), then
    /// the story's errors and warnings, written in that order as the harness flushes them.
    events: std.ArrayList(u8) = .empty,
    errors: std.ArrayList(u8) = .empty,
    warnings: std.ArrayList(u8) = .empty,
    bindings: std.ArrayList(*Bound) = .empty,

    pub fn init(harness: *Harness, gpa: std.mem.Allocator, json: []const u8) !void {
        harness.* = .{ .gpa = gpa, .program = try ink_json.load(gpa, json), .story = undefined };
        errdefer harness.program.deinit(gpa);
        try harness.start_story();
    }

    fn start_story(harness: *Harness) !void {
        try harness.story.init(harness.gpa, &harness.program, .{});
        harness.story.on_error = on_error;
        harness.story.on_error_context = harness;
    }

    pub fn deinit(harness: *Harness) void {
        const gpa = harness.gpa;
        harness.tag_bytes.deinit(gpa);
        harness.tag_ends.deinit(gpa);
        gpa.free(harness.exception);
        harness.saved.deinit(gpa);
        harness.events.deinit(gpa);
        harness.errors.deinit(gpa);
        harness.warnings.deinit(gpa);
        for (harness.bindings.items) |bound| bound.release(gpa);
        harness.bindings.deinit(gpa);
        harness.story.deinit(gpa);
        harness.program.deinit(gpa);
        harness.* = undefined;
    }

    /// Replays every action in `actions`, writing the transcript (without the harness's
    /// provenance header). An error stops it with `exception: "<message>"`, like an ink
    /// exception in the harness.
    pub fn replay(harness: *Harness, actions: []const u8, writer: *std.Io.Writer) !void {
        var lines = std.mem.splitScalar(u8, actions, '\n');
        while (lines.next()) |line| {
            const action = try transcript.parse_action(line) orelse continue;
            try writer.print("> {s}\n", .{std.mem.trim(u8, line, " \t\r")});
            harness.apply(action, writer) catch |err| switch (err) {
                error.WriteFailed, error.OutOfMemory => |fatal| return fatal,
                else => {
                    try harness.write_messages(writer);
                    try writer.writeAll("exception: ");
                    const message = if (harness.exception.len > 0)
                        harness.exception
                    else
                        @errorName(err);
                    try write_json_string(writer, message);
                    try writer.writeByte('\n');
                    return;
                },
            };
            try harness.write_messages(writer);
        }
    }

    fn apply(harness: *Harness, action: transcript.Action, writer: *std.Io.Writer) anyerror!void {
        const story = &harness.story;
        const argument = action.argument;
        switch (action.kind) {
            .seed => story.set_random_seed(try std.fmt.parseInt(i32, argument, 10)),
            .@"continue" => try harness.continue_once(writer),
            .continue_maximally => try harness.continue_maximally(writer),
            .choices => try harness.write_choices(writer),
            .choose => try story.choose_choice_index(try std.fmt.parseInt(u32, argument, 10)),
            .play => try harness.play(writer, null),
            .play_seeded => {
                var random = DotnetRandom.init(try std.fmt.parseInt(i32, argument, 10));
                try harness.play(writer, &random);
            },
            .globals => try harness.write_globals(writer),
            .choose_path => try harness.choose_path(argument),
            .evaluate => try harness.evaluate(argument, writer),
            .get => {
                try writer.writeAll("value: ");
                try harness.write_variable(writer, argument);
                try writer.writeByte('\n');
            },
            .set => try harness.set(argument),
            .observe => try story.observe_variable(argument, observed, harness),
            .bind => try harness.bind(argument),
            .unbind => try story.unbind_external_function(argument),
            .fallbacks => story.allow_external_function_fallbacks = std.mem.eql(u8, argument, "on"),
            .save => try harness.save(writer),
            .load => try load_module.load_json(story, harness.saved.items),
            .load_fresh => try harness.load_fresh(),
            .current_text => {
                try writer.writeAll("current_text: ");
                try write_json_string(writer, try story.current_text());
                try writer.writeByte('\n');
            },
            .reset => try story.reset_state(),
            .switch_flow => try story.switch_flow(argument),
            .remove_flow => try story.remove_flow(argument),
            .default_flow => try story.switch_to_default_flow(),
            .visit_count => try writer.print("visit_count: {d}\n", .{
                story_paths.visit_count_at_path_string(story, argument),
            }),
            .tags_at => try harness.write_path_tags(argument, writer),
            .global_tags => try harness.write_path_tags(null, writer),
            .events => story.events = .{
                .context = harness,
                .on_did_continue = did_continue,
                .on_make_choice = make_choice,
                .on_evaluate_function = evaluate_function,
                .on_complete_evaluate_function = complete_evaluate_function,
                .on_choose_path_string = choose_path_string,
            },
        }
    }

    fn continue_once(harness: *Harness, writer: *std.Io.Writer) !void {
        const story = &harness.story;
        if (!story.can_continue()) return writer.writeAll("can_continue: false\n");
        const text = story.cont() catch |err| {
            if (err == error.MissingExternalBinding) try harness.missing_binding_exception();
            return err;
        };
        try writer.writeAll("text: ");
        try write_json_string(writer, text);
        try writer.writeByte('\n');
        harness.clear_tags();
        try story.current_tags(harness);
        if (harness.tag_ends.items.len > 0) {
            try writer.writeAll("tags: ");
            try harness.write_tags(writer);
            try writer.writeByte('\n');
        }
        // The harness flushes host events and messages after each line.
        try harness.write_messages(writer);
    }

    fn continue_maximally(harness: *Harness, writer: *std.Io.Writer) !void {
        const lines_max = 100_000;
        for (0..lines_max) |_| {
            if (!harness.story.can_continue()) return;
            try harness.continue_once(writer);
        }
        return error.ContinueLimit;
    }

    fn write_choices(harness: *Harness, writer: *std.Io.Writer) !void {
        const story = &harness.story;
        const count = story.visible_choices_count();
        try writer.print("choices: {d}\n", .{count});
        for (0..count) |position| {
            const choice = story.visible_choice(@intCast(position));
            try writer.print("  {d}: ", .{position});
            try write_json_string(writer, story.text_of(choice.text));
            const all = story.state.choices.tags.slice();
            harness.clear_tags();
            for (all[choice.tags_first..][0..choice.tags_count]) |reference| {
                try harness.tag(story.text_of(reference));
            }
            if (choice.tags_count > 0) {
                try writer.writeAll(" tags ");
                try harness.write_tags(writer);
            }
            try writer.writeByte('\n');
        }
    }

    /// Continues maximally and makes a choice until the story ends or `turns_max`: the first
    /// choice, or one picked by `random` (`Next() % count`) when it is given.
    fn play(harness: *Harness, writer: *std.Io.Writer, random: ?*DotnetRandom) !void {
        for (0..transcript.turns_max) |_| {
            try harness.continue_maximally(writer);
            try harness.write_choices(writer);
            const count = harness.story.visible_choices_count();
            if (count == 0) return writer.writeAll("end\n");
            const index = if (random) |generator| pick(generator, count) else 0;
            try writer.print("choose: {d}\n", .{index});
            try harness.story.choose_choice_index(index);
        }
        try writer.writeAll("turns_max reached\n");
    }

    /// The tag sink for the story's tag queries.
    pub fn tag(harness: *Harness, text: []const u8) !void {
        try harness.tag_bytes.appendSlice(harness.gpa, text);
        try harness.tag_ends.append(harness.gpa, @intCast(harness.tag_bytes.items.len));
    }

    fn clear_tags(harness: *Harness) void {
        harness.tag_bytes.clearRetainingCapacity();
        harness.tag_ends.clearRetainingCapacity();
    }

    fn write_tags(harness: *const Harness, writer: *std.Io.Writer) !void {
        try writer.writeByte('[');
        var start: u32 = 0;
        for (harness.tag_ends.items, 0..) |end, position| {
            if (position > 0) try writer.writeAll(", ");
            try write_json_string(writer, harness.tag_bytes.items[start..end]);
            start = end;
        }
        try writer.writeByte(']');
    }

    /// `tags_at <path>`, or the global tags when `path` is null.
    fn write_path_tags(harness: *Harness, path: ?[]const u8, writer: *std.Io.Writer) !void {
        harness.clear_tags();
        if (path) |text| {
            story_paths.tags_at_path(&harness.story, text, harness) catch |err| {
                if (err == error.PathNotFound) try harness.path_exception(text);
                return err;
            };
        } else {
            try story_paths.global_tags(&harness.story, harness);
        }
        try writer.writeAll("tags: ");
        try harness.write_tags(writer);
        try writer.writeByte('\n');
    }

    fn set_exception(harness: *Harness, comptime format: []const u8, arguments: anytype) !void {
        harness.gpa.free(harness.exception);
        harness.exception = &.{};
        harness.exception = try std.fmt.allocPrint(harness.gpa, format, arguments);
    }

    fn path_exception(harness: *Harness, path: []const u8) !void {
        try harness.set_exception("Failed to find content at path '{s}', and no approximation " ++
            "of it was possible.", .{path});
    }

    /// ink's ValidateExternalBindings message.
    fn missing_binding_exception(harness: *Harness) !void {
        var names: NameList = .{ .gpa = harness.gpa };
        defer names.list.deinit(harness.gpa);
        try harness.story.missing_externals(&names);
        assert(names.count > 0);
        const suffix = if (harness.story.allow_external_function_fallbacks)
            ", and no fallback ink function found."
        else
            " (ink fallbacks disabled)";
        try harness.set_exception("ERROR: Missing function binding for external{s}: '{s}' {s}", .{
            if (names.count > 1) "s" else "", names.list.items, suffix,
        });
    }

    /// `set <variable> <typed value>`.
    fn set(harness: *Harness, argument: []const u8) !void {
        const space = std.mem.indexOfScalar(u8, argument, ' ') orelse
            return error.BadActionArgument;
        const name = argument[0..space];
        var buffer: [4096]u8 = undefined;
        const story = &harness.story;
        const result = switch (try transcript.parse_typed(argument[space + 1 ..], &buffer)) {
            .integer => |number| story.set_variable(name, .{ .integer = number }),
            .float => |number| story.set_variable(name, .{ .float = number }),
            .bool => |flag| story.set_variable(name, .{ .bool = flag }),
            .string => |text| story.set_variable_text(name, text),
            else => unreachable,
        };
        result catch |err| {
            if (err == error.VariableNotDeclared) try harness.set_exception(
                "Cannot assign to a variable ({s}) that hasn't been declared in the story",
                .{name},
            );
            return err;
        };
    }

    /// A global's value, or `null` when there is no such global.
    fn write_variable(harness: *Harness, writer: *std.Io.Writer, name: []const u8) !void {
        const story = &harness.story;
        const value = story.get_variable(name) orelse return writer.writeAll("null");
        try write_host_value(harness.gpa, story, writer, ops.host_value(story, value));
    }

    /// Every global, sorted by name.
    fn write_globals(harness: *Harness, writer: *std.Io.Writer) !void {
        const program = &harness.program;
        const names = try harness.gpa.alloc([]const u8, program.globals.len);
        defer harness.gpa.free(names);
        for (names, program.globals) |*name, global| name.* = program.strings.get(global.name);
        std.mem.sort([]const u8, names, {}, less_than);
        for (names) |name| {
            try writer.print("global: {s} = ", .{name});
            try harness.write_variable(writer, name);
            try writer.writeByte('\n');
        }
    }

    fn less_than(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.order(u8, a, b) == .lt;
    }

    /// `evaluate <function> [<typed value>...]`: the function's text and result.
    fn evaluate(harness: *Harness, argument: []const u8, writer: *std.Io.Writer) !void {
        const space = std.mem.indexOfScalar(u8, argument, ' ');
        const name = if (space) |at| argument[0..at] else argument;
        var arguments: transcript.Arguments = .{};
        var buffer: [4096]u8 = undefined;
        if (space) |at| try transcript.parse_typed_list(argument[at + 1 ..], &buffer, &arguments);
        var text: std.Io.Writer.Allocating = .init(harness.gpa);
        defer text.deinit();
        const story = &harness.story;
        const result = evaluate_module.evaluate_function(
            story,
            name,
            arguments.slice(),
            &text.writer,
        ) catch |err| {
            if (err == error.FunctionNotFound) {
                try harness.set_exception("Function doesn't exist: '{s}'", .{name});
            }
            return err;
        };
        try writer.writeAll("text: ");
        try write_json_string(writer, text.written());
        try writer.writeAll("\nresult: ");
        try write_host_value(harness.gpa, story, writer, result);
        try writer.writeByte('\n');
    }

    fn choose_path(harness: *Harness, path: []const u8) !void {
        story_paths.choose_path_string(&harness.story, path, true, &.{}) catch |err| {
            if (err == error.PathNotFound) try harness.path_exception(path);
            return err;
        };
    }

    /// `save`: the state's JSON, kept for `load` and `load_fresh`.
    fn save(harness: *Harness, writer: *std.Io.Writer) !void {
        harness.saved.clearRetainingCapacity();
        var saving: std.Io.Writer.Allocating = .fromArrayList(harness.gpa, &harness.saved);
        defer harness.saved = saving.toArrayList();
        try save_module.to_json(&harness.story, &saving.writer);
        try writer.print("save: {s}\n", .{saving.written()});
    }

    /// `load_fresh`: a new story from the same program, then the last save, as when a game
    /// restarts. Bindings, observers and the error handler start over, as in the harness.
    fn load_fresh(harness: *Harness) !void {
        harness.story.deinit(harness.gpa);
        for (harness.bindings.items) |bound| bound.release(harness.gpa);
        harness.bindings.clearRetainingCapacity();
        try harness.start_story();
        try load_module.load_json(&harness.story, harness.saved.items);
    }

    /// `bind <function> <behaviour> [lookahead_unsafe]`, as the harness binds.
    fn bind(harness: *Harness, argument: []const u8) !void {
        var words = std.mem.tokenizeScalar(u8, argument, ' ');
        const name = words.next() orelse return error.BadActionArgument;
        const behaviour_text = words.next() orelse return error.BadActionArgument;
        const behaviour = std.meta.stringToEnum(Behaviour, behaviour_text) orelse
            return error.BadActionArgument;
        const bound = try harness.gpa.create(Bound);
        errdefer harness.gpa.destroy(bound);
        const owned_name = try harness.gpa.dupe(u8, name);
        bound.* = .{ .harness = harness, .name = owned_name, .behaviour = behaviour };
        try harness.bindings.append(harness.gpa, bound);
        var rest = words.rest();
        if (behaviour == .@"return") rest = try bound.take_constant(harness.gpa, rest);
        if (behaviour == .increment_and_evaluate) {
            var function_words = std.mem.tokenizeScalar(u8, rest, ' ');
            bound.function = try harness.gpa.dupe(
                u8,
                function_words.next() orelse return error.BadActionArgument,
            );
            rest = function_words.rest();
        }
        const lookahead_safe = !std.mem.eql(u8, std.mem.trim(u8, rest, " "), "lookahead_unsafe");
        try harness.story.bind_external_function(name, Bound.call, bound, lookahead_safe);
    }

    fn write_messages(harness: *Harness, writer: *std.Io.Writer) !void {
        try writer.writeAll(harness.events.items);
        try writer.writeAll(harness.errors.items);
        try writer.writeAll(harness.warnings.items);
        harness.events.clearRetainingCapacity();
        harness.errors.clearRetainingCapacity();
        harness.warnings.clearRetainingCapacity();
    }
};

/// `Next() % count`, as a host would pick a choice with .NET's Random.
fn pick(random: *DotnetRandom, count: u32) u32 {
    assert(count > 0);
    return @intCast(@mod(random.next(), @as(i32, @intCast(count))));
}

/// The sink for `missing_externals`: the names joined with `', '`.
const NameList = struct {
    gpa: std.mem.Allocator,
    list: std.ArrayList(u8) = .empty,
    count: u32 = 0,

    pub fn name(names: *NameList, text: []const u8) !void {
        if (names.count > 0) try names.list.appendSlice(names.gpa, "', '");
        try names.list.appendSlice(names.gpa, text);
        names.count += 1;
    }
};

const Behaviour = enum { record, @"return", multiply, repeat, increment_and_evaluate };

/// One binding made by `bind`, the callback's context.
const Bound = struct {
    harness: *Harness,
    name: []u8,
    behaviour: Behaviour,
    constant: HostValue = .null,
    constant_text: []u8 = &.{},
    function: []u8 = &.{},
    result: std.ArrayList(u8) = .empty,

    fn release(bound: *Bound, gpa: std.mem.Allocator) void {
        gpa.free(bound.name);
        gpa.free(bound.constant_text);
        gpa.free(bound.function);
        bound.result.deinit(gpa);
        gpa.destroy(bound);
    }

    /// Parses `return`'s typed value; returns the rest of the argument.
    fn take_constant(bound: *Bound, gpa: std.mem.Allocator, rest: []const u8) ![]const u8 {
        var buffer: [4096]u8 = undefined;
        bound.constant = try transcript.parse_typed(rest, &buffer);
        // A string constant is the last word; others are one word.
        if (bound.constant == .string) {
            bound.constant_text = try gpa.dupe(u8, bound.constant.string);
            bound.constant = .{ .string = bound.constant_text };
            return "";
        }
        var words = std.mem.tokenizeScalar(u8, rest, ' ');
        _ = words.next();
        _ = words.next();
        return words.rest();
    }

    fn call(context: ?*anyopaque, story: *Story, arguments: []const HostValue) anyerror!HostValue {
        const bound: *Bound = @ptrCast(@alignCast(context.?));
        assert(&bound.harness.story == story);
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
    fn record(bound: *Bound, arguments: []const HostValue) !void {
        const harness = bound.harness;
        var writer: std.Io.Writer.Allocating = .fromArrayList(harness.gpa, &harness.events);
        defer harness.events = writer.toArrayList();
        try writer.writer.print("external: {s}", .{bound.name});
        try write_arguments(harness, &writer.writer, arguments);
        try writer.writer.writeByte('\n');
    }

    /// `EvaluateFunction(<ink function>, x + 1)` from inside the external, discarding the
    /// function's text as ink's overload without `out` text does.
    fn increment_and_evaluate(
        bound: *Bound,
        story: *Story,
        arguments: []const HostValue,
    ) !HostValue {
        assert(arguments.len == 1 and arguments[0] == .integer);
        var discarding: std.Io.Writer.Discarding = .init(&.{});
        const argument: HostValue = .{ .integer = arguments[0].integer +% 1 };
        return evaluate_module.evaluate_function(
            story,
            bound.function,
            &.{argument},
            &discarding.writer,
        );
    }

    fn multiply(arguments: []const HostValue) HostValue {
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

    fn repeat(bound: *Bound, arguments: []const HostValue) !HostValue {
        assert(arguments.len == 2);
        assert(arguments[0] == .integer and arguments[1] == .string);
        const gpa = bound.harness.gpa;
        bound.result.clearRetainingCapacity();
        const times: usize = @intCast(@max(arguments[0].integer, 0));
        for (0..times) |_| try bound.result.appendSlice(gpa, arguments[1].string);
        return .{ .string = bound.result.items };
    }
};

// The story's callbacks; each gets the harness as its context and appends a line to
// `events`, `errors` or `warnings`. A failed write drops the line, as callbacks can't fail.

fn harness_of(context: ?*anyopaque) *Harness {
    return @ptrCast(@alignCast(context.?));
}

fn append_line(harness: *Harness, list: *std.ArrayList(u8), parts: anytype) void {
    var writer: std.Io.Writer.Allocating = .fromArrayList(harness.gpa, list);
    defer list.* = writer.toArrayList();
    write_parts(harness, &writer.writer, parts) catch return;
    writer.writer.writeByte('\n') catch return;
}

/// Writes each part: `[]const u8` as is, `Json` escaped, a `HostValue` or `[]const HostValue`
/// as the harness renders values.
fn write_parts(harness: *Harness, writer: *std.Io.Writer, parts: anytype) !void {
    inline for (parts) |part| switch (@TypeOf(part)) {
        Json => try write_json_string(writer, part.text),
        HostValue => try write_host_value(harness.gpa, &harness.story, writer, part),
        []const HostValue => try write_arguments(harness, writer, part),
        else => try writer.writeAll(part),
    };
}

const Json = struct { text: []const u8 };

fn did_continue(context: ?*anyopaque) void {
    const harness = harness_of(context);
    append_line(harness, &harness.events, .{"event: did_continue"});
}

fn make_choice(context: ?*anyopaque, text: []const u8, _: u32) void {
    const harness = harness_of(context);
    append_line(harness, &harness.events, .{ "event: make_choice ", Json{ .text = text } });
}

fn evaluate_function(context: ?*anyopaque, name: []const u8, arguments: []const HostValue) void {
    const harness = harness_of(context);
    append_line(harness, &harness.events, .{ "event: evaluate_function ", name, arguments });
}

fn complete_evaluate_function(
    context: ?*anyopaque,
    name: []const u8,
    arguments: []const HostValue,
    text: []const u8,
    result: HostValue,
) void {
    const harness = harness_of(context);
    append_line(harness, &harness.events, .{
        "event: complete_evaluate_function ", name, arguments, " ", Json{ .text = text }, " ",
        result,
    });
}

fn choose_path_string(context: ?*anyopaque, path: []const u8, arguments: []const HostValue) void {
    const harness = harness_of(context);
    append_line(harness, &harness.events, .{ "event: choose_path_string ", path, arguments });
}

/// `observed: name = value`, as the harness's observer records it.
fn observed(context: ?*anyopaque, name: []const u8, value: HostValue) void {
    const harness = harness_of(context);
    append_line(harness, &harness.events, .{ "observed: ", name, " = ", value });
}

fn on_error(context: ?*anyopaque, message: []const u8, severity: Severity) void {
    const harness = harness_of(context);
    if (severity == .@"error") {
        append_line(harness, &harness.errors, .{ "error: ", Json{ .text = message } });
    } else {
        append_line(harness, &harness.warnings, .{ "warning: ", Json{ .text = message } });
    }
}

/// `(a, b)`, each argument rendered like the harness renders values.
fn write_arguments(harness: *Harness, writer: *std.Io.Writer, arguments: []const HostValue) !void {
    try writer.writeByte('(');
    for (arguments, 0..) |argument, position| {
        if (position > 0) try writer.writeAll(", ");
        try write_host_value(harness.gpa, &harness.story, writer, argument);
    }
    try writer.writeByte(')');
}

/// A host value as the harness renders one: `int 5`, `float 2.5`, `bool true`,
/// `string "a"`, `list "A.x, B.y"`, `other "<divert target's path>"` or `null`.
fn write_host_value(
    gpa: std.mem.Allocator,
    story: *Story,
    writer: *std.Io.Writer,
    value: HostValue,
) !void {
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
            try write_json_string(writer, text);
        },
        .list => |list| {
            var text: std.Io.Writer.Allocating = .init(gpa);
            defer text.deinit();
            try story.write_list(list, &text.writer);
            try writer.writeAll("list ");
            try write_json_string(writer, text.written());
        },
        .divert_target => |target| {
            try writer.writeAll("other ");
            try write_json_string(writer, story.path_of(target));
        },
    }
}
