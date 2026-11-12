//! The new runtime (`src/vm/`) behind the engine-neutral layer (plan P0.11, P5.1). It is
//! line-based like ink, so `continue_line` is one `cont()` and tags are per line.

const std = @import("std");
const assert = std.debug.assert;
const transcript = @import("transcript.zig");
const ink_json = @import("../core/ink_json.zig");
const Program = @import("../core/program.zig").Program;
const Story = @import("../vm/story.zig").Story;

pub const NewEngine = struct {
    pub const tags_per_line = true;

    gpa: std.mem.Allocator,
    /// Heap-allocated so the story's borrowed pointer stays valid when the engine moves.
    program: *Program,
    story: *Story,
    /// The tags of the last line or choice, owned until the next call that returns tags.
    tags: std.ArrayList([]const u8) = .empty,
    tag_bytes: std.ArrayList(u8) = .empty,

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
};
