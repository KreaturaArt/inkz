//! The new runtime (`src/vm/`) behind the engine-neutral layer (plan P0.11, P5.1). It is
//! line-based like ink, so `continue_line` is one `cont()` and tags are per line.

const std = @import("std");
const assert = std.debug.assert;
const transcript = @import("transcript.zig");
const ink_json = @import("../core/ink_json.zig");
const Program = @import("../core/program.zig").Program;
const Story = @import("../vm/story.zig").Story;
const value_module = @import("../vm/value.zig");

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

    pub fn open(gpa: std.mem.Allocator, json: []const u8) !NewEngine {
        assert(json.len > 0);
        const program = try gpa.create(Program);
        errdefer gpa.destroy(program);
        program.* = try ink_json.load(gpa, json);
        errdefer program.deinit(gpa);
        const story = try gpa.create(Story);
        errdefer gpa.destroy(story);
        try story.init(gpa, program, .{});
        const engine: NewEngine = .{ .gpa = gpa, .program = program, .story = story };
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
        const text = try engine.story.cont();
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
};
