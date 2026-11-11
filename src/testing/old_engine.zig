//! The old runtime (`src/runtime/story.zig`) behind the engine-neutral layer (plan P0.11).
//!
//! The old `cont()` runs a whole turn (ink's `ContinueMaximally`, divergence S2), so this
//! adapter splits each turn into lines. Tags are only known per turn (S11): they are reported
//! with the last line of the turn, and `tags_per_line` is false so comparisons know that.

const std = @import("std");
const assert = std.debug.assert;
const transcript = @import("transcript.zig");
const Story = @import("../runtime/story.zig").Story;

/// Weave-heuristic firings of every old engine in this process (plan P0.12), added when an
/// engine is deinitialized or replaced.
pub var heuristic_totals: HeuristicCounts = .{};

pub const HeuristicCounts = struct {
    loop_back_gather_tail: u32 = 0,
    divert_ancestor_of_choice_source: u32 = 0,

    fn add(total: *HeuristicCounts, story: *const Story) void {
        const counts = story.heuristic_counts;
        total.loop_back_gather_tail += counts.loop_back_gather_tail;
        total.divert_ancestor_of_choice_source += counts.divert_ancestor_of_choice_source;
        assert(total.loop_back_gather_tail >= counts.loop_back_gather_tail);
        assert(total.divert_ancestor_of_choice_source >= counts.divert_ancestor_of_choice_source);
    }
};

pub const OldEngine = struct {
    pub const tags_per_line = false;

    gpa: std.mem.Allocator,
    /// The story JSON, kept for `load_fresh`.
    json: []const u8,
    story: Story,
    /// The current turn's text, owned, and how much of it has been returned as lines.
    turn_text: []u8,
    turn_offset: u32,
    choice_buffer: [1]transcript.Choice = undefined,
    /// The last save, owned, for `load` and `load_fresh`.
    saved: []u8 = &.{},
    tags: [][]const u8 = &.{},
    names: [][]const u8 = &.{},

    pub fn init(gpa: std.mem.Allocator, json: []const u8) !OldEngine {
        var story = try Story.initFromJson(gpa, json);
        errdefer story.deinit();
        // Deterministic like the harness: ink seeds from the clock otherwise.
        story.state.story_seed = 0;
        const engine: OldEngine = .{
            .gpa = gpa,
            .json = json,
            .story = story,
            .turn_text = &.{},
            .turn_offset = 0,
        };
        assert(engine.turn_text.len == 0);
        assert(engine.story.state.story_seed == 0);
        return engine;
    }

    pub fn deinit(engine: *OldEngine) void {
        assert(engine.turn_offset <= engine.turn_text.len);
        assert(engine.choices_count() <= engine.story.currentChoices().len);
        engine.gpa.free(engine.turn_text);
        engine.gpa.free(engine.saved);
        engine.gpa.free(engine.tags);
        engine.gpa.free(engine.names);
        heuristic_totals.add(&engine.story);
        engine.story.deinit();
        engine.* = undefined;
    }

    pub fn can_continue(engine: *const OldEngine) bool {
        assert(engine.turn_offset <= engine.turn_text.len);
        const pending = engine.turn_offset < engine.turn_text.len;
        const result = pending or engine.story.canContinue();
        if (pending) assert(result);
        return result;
    }

    /// The next line of the current turn, running the next turn first if this one is used up.
    pub fn continue_line(engine: *OldEngine) !transcript.Line {
        assert(engine.can_continue());
        if (engine.turn_offset == engine.turn_text.len) {
            engine.gpa.free(engine.turn_text);
            engine.turn_text = &.{};
            engine.turn_text = try engine.story.cont();
            engine.turn_offset = 0;
        }
        const rest = engine.turn_text[engine.turn_offset..];
        const newline = std.mem.indexOfScalar(u8, rest, '\n');
        const length = if (newline) |at| at + 1 else rest.len;
        engine.turn_offset += @intCast(length);
        const is_last = engine.turn_offset == engine.turn_text.len;
        const tags = if (is_last) engine.story.currentTags() else &.{};
        assert(engine.turn_offset <= engine.turn_text.len);
        return .{ .text = rest[0..length], .tags = tags };
    }

    pub fn choices_count(engine: *const OldEngine) u32 {
        // Choices only exist once the turn's lines have all been returned.
        assert(engine.turn_offset <= engine.turn_text.len);
        if (engine.turn_offset < engine.turn_text.len) return 0;
        const count: u32 = @intCast(engine.story.currentChoices().len);
        assert(count == engine.story.currentChoices().len);
        return count;
    }

    pub fn choice(engine: *OldEngine, index: u32) transcript.Choice {
        const choices = engine.story.currentChoices();
        assert(index < choices.len);
        engine.choice_buffer[0] = .{ .text = choices[index].text, .tags = choices[index].tags };
        assert(engine.choice_buffer[0].text.len == choices[index].text.len);
        return engine.choice_buffer[0];
    }

    pub fn choose(engine: *OldEngine, index: u32) !void {
        assert(index < engine.choices_count());
        assert(engine.turn_offset == engine.turn_text.len);
        try engine.story.chooseChoiceIndex(index);
    }

    pub fn seed(engine: *OldEngine, value: i32) void {
        // The old runtime stores the seed as u32 and takes abs (divergence S7).
        engine.story.state.story_seed = @abs(value);
        assert(engine.story.state.story_seed == @abs(value));
        assert(engine.turn_offset <= engine.turn_text.len);
    }


    pub fn choose_path(engine: *OldEngine, path: []const u8) !void {
        assert(path.len > 0);
        engine.discard_turn();
        try engine.story.choosePathString(path);
        assert(engine.turn_offset == engine.turn_text.len);
    }

    pub fn switch_flow(engine: *OldEngine, name: []const u8) !void {
        assert(name.len > 0);
        engine.discard_turn();
        try engine.story.switchFlow(name);
        assert(engine.turn_offset == engine.turn_text.len);
    }

    pub fn remove_flow(engine: *OldEngine, name: []const u8) !void {
        assert(name.len > 0);
        engine.discard_turn();
        try engine.story.removeFlow(name);
        assert(engine.turn_offset == engine.turn_text.len);
    }

    pub fn default_flow(engine: *OldEngine, argument: []const u8) !void {
        assert(argument.len == 0);
        engine.discard_turn();
        try engine.story.switchToDefaultFlow();
        assert(engine.turn_offset == engine.turn_text.len);
    }

    pub fn get(engine: *OldEngine, name: []const u8) !transcript.Value {
        assert(name.len > 0);
        const value = engine.story.state.variables_state.get(name) orelse return .null;
        const result: transcript.Value = switch (value) {
            .void => .null,
            .int => |number| .{ .int = number },
            .float => |number| .{ .float = number },
            .bool => |flag| .{ .bool = flag },
            .string => |text| .{ .string = text },
            .divert_target => |path| .{ .other = path },
            else => .{ .other = @tagName(value) },
        };
        assert(result != .string or result.string.len == value.string.len);
        return result;
    }

    /// Global variable names, sorted so transcripts don't depend on hash order.
    pub fn global_names(engine: *OldEngine) ![]const []const u8 {
        const globals = &engine.story.state.variables_state.globals;
        assert(globals.count() < 1 << 20);
        const names = try engine.gpa.alloc([]const u8, globals.count());
        var iterator = globals.keyIterator();
        var index: u32 = 0;
        while (iterator.next()) |key| : (index += 1) names[index] = key.*;
        std.mem.sort([]const u8, names, {}, name_less_than);
        engine.gpa.free(engine.names);
        engine.names = names;
        assert(index == names.len);
        return names;
    }

    fn name_less_than(_: void, a: []const u8, b: []const u8) bool {
        assert(a.len > 0);
        assert(b.len > 0);
        return std.mem.order(u8, a, b) == .lt;
    }

    pub fn visit_count(engine: *OldEngine, path: []const u8) !u32 {
        assert(path.len > 0);
        const count = engine.story.visitCountAtPathString(path);
        assert(count < std.math.maxInt(u32));
        return count;
    }

    pub fn global_tags(engine: *OldEngine) ![]const []const u8 {
        assert(engine.turn_offset <= engine.turn_text.len);
        engine.gpa.free(engine.tags);
        engine.tags = &.{};
        engine.tags = try engine.story.globalTags();
        assert(engine.tags.len < 1024);
        return engine.tags;
    }

    pub fn save(engine: *OldEngine) ![]const u8 {
        assert(engine.turn_offset <= engine.turn_text.len);
        engine.gpa.free(engine.saved);
        engine.saved = &.{};
        engine.saved = try engine.story.toJson(engine.gpa);
        assert(engine.saved.len > 0);
        return engine.saved;
    }

    pub fn load(engine: *OldEngine) !void {
        assert(engine.turn_offset <= engine.turn_text.len);
        if (engine.saved.len == 0) return error.NothingSaved;
        engine.discard_turn();
        try engine.story.loadStateFromJson(engine.saved);
        assert(engine.turn_offset == engine.turn_text.len);
    }

    /// Loads the last save into a new story built from the same JSON.
    pub fn load_fresh(engine: *OldEngine) !void {
        assert(engine.json.len > 0);
        if (engine.saved.len == 0) return error.NothingSaved;
        var fresh = try Story.initFromJson(engine.gpa, engine.json);
        errdefer fresh.deinit();
        fresh.state.story_seed = 0;
        try fresh.loadStateFromJson(engine.saved);
        heuristic_totals.add(&engine.story);
        engine.story.deinit();
        engine.story = fresh;
        engine.discard_turn();
        assert(engine.turn_offset == engine.turn_text.len);
    }

    /// Drops the rest of the current turn: the old runtime has already run it.
    fn discard_turn(engine: *OldEngine) void {
        assert(engine.turn_offset <= engine.turn_text.len);
        engine.gpa.free(engine.turn_text);
        engine.turn_text = &.{};
        engine.turn_offset = 0;
        assert(engine.turn_text.len == 0);
    }
};

/// Plays `fixture` with `actions` on the old engine and returns the transcript.
pub fn replay_fixture(gpa: std.mem.Allocator, fixture: []const u8, actions: []const u8) ![]u8 {
    assert(fixture.len > 0);
    const io = std.testing.io;
    const json = try std.Io.Dir.cwd().readFileAlloc(io, fixture, gpa, .limited(4 * 1024 * 1024));
    defer gpa.free(json);
    var engine = try OldEngine.init(gpa, json);
    defer engine.deinit();
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    try transcript.replay(&engine, actions, &output.writer);
    const text = try output.toOwnedSlice();
    assert(text.len > 0 or actions.len == 0);
    return text;
}

/// The `text:` lines of a transcript joined back into the story's raw output.
fn played_text(gpa: std.mem.Allocator, fixture: []const u8, actions: []const u8) ![]u8 {
    assert(fixture.len > 0);
    const text = try replay_fixture(gpa, fixture, actions);
    defer gpa.free(text);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "text: \"")) continue;
        try unescape_json_string(gpa, &output, line["text: ".len..]);
    }
    assert(output.items.len <= text.len);
    return output.toOwnedSlice(gpa);
}

fn unescape_json_string(
    gpa: std.mem.Allocator,
    output: *std.ArrayList(u8),
    quoted: []const u8,
) !void {
    assert(quoted.len >= 2);
    assert(quoted[0] == '"' and quoted[quoted.len - 1] == '"');
    const parsed = try std.json.parseFromSlice([]const u8, gpa, quoted, .{});
    defer parsed.deinit();
    try output.appendSlice(gpa, parsed.value);
}

// These tests replace the old `runStory` helper tests in src/test/helpers.zig: the same
// fixtures and expectations, driven through the engine-neutral layer.

const fixtures = "test/fixture/compiled/runtime/";

fn expect_played_contains(
    fixture: []const u8,
    actions: []const u8,
    needles: []const []const u8,
) !void {
    assert(fixture.len > 0);
    assert(actions.len > 0);
    const gpa = std.testing.allocator;
    const text = try played_text(gpa, fixture, actions);
    defer gpa.free(text);
    try std.testing.expect(text.len > 0);
    for (needles) |needle| {
        if (std.mem.indexOf(u8, text, needle) == null) {
            std.debug.print("missing '{s}' in:\n{s}\n", .{ needle, text });
            return error.TestExpectedText;
        }
    }
}

test "layer: hello_world" {
    const gpa = std.testing.allocator;
    const text = try replay_fixture(gpa, fixtures ++ "misc/hello_world.ink.json", "play");
    defer gpa.free(text);
    try std.testing.expectEqualStrings(
        "> play\ntext: \"Hello world\\n\"\nchoices: 0\nend\n",
        text,
    );
}

test "layer: conditionals and else branches" {
    try expect_played_contains(fixtures ++ "conditions/conditionals.ink.json", "play", &.{"true"});
    try expect_played_contains(fixtures ++ "conditions/else_branches.ink.json", "play", &.{});
}

test "layer: logic lines with newlines" {
    // func() is called twice, so "text 2" appears twice.
    const gpa = std.testing.allocator;
    const fixture = fixtures ++ "logic/logic_lines_with_newlines.ink.json";
    const text = try played_text(gpa, fixture, "play");
    defer gpa.free(text);
    try std.testing.expect(std.mem.count(u8, text, "text 2") >= 2);
}

test "layer: weave gathers, both paths" {
    const weave = fixtures ++ "weaves/weave_gathers.ink.json";
    // "one" then "two" leads to "three" and "six".
    try expect_played_contains(weave, "play", &.{ "three", "six" });
    // "four" leads to "five" and "six".
    try expect_played_contains(weave, "continue_maximally\nchoose 1\nplay", &.{ "five", "six" });
}

test "layer: arithmetic, recursion, tunnels and lists produce output" {
    try expect_played_contains(fixtures ++ "evaluation/arithmetic.ink.json", "play", &.{});
    // 5! = 120
    const factorial = fixtures ++ "evaluation/factorial_recursive.ink.json";
    try expect_played_contains(factorial, "play", &.{"120"});
    try expect_played_contains(fixtures ++ "diverts/basic_tunnel.ink.json", "play", &.{});
    try expect_played_contains(fixtures ++ "lists/list_basic_operations.ink.json", "play", &.{});
}

test "layer: a turn is split into lines and choices come after the last one" {
    // Goal: the adapter's turn splitting. Method: continue once per line through the weave and
    // check the transcript: no choices while lines are pending.
    const gpa = std.testing.allocator;
    const actions = "continue_maximally\nchoose 0\ncontinue\nchoices\n";
    const text = try replay_fixture(gpa, fixtures ++ "weaves/weave_gathers.ink.json", actions);
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "> continue\ntext: \"one\\n\"\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "> choices\nchoices: 1\n  0: \"two\"\n"));
}

test "layer: weave heuristic firings are counted (P0.12)" {
    // Goal: the instrumentation behind `zig build heuristics-report`. Method: play a weave
    // fixture where the divert-to-ancestor heuristic is known to fire and check the total.
    const gpa = std.testing.allocator;
    const before = heuristic_totals.divert_ancestor_of_choice_source;
    const fixture = fixtures ++ "weaves/conditional_choice_in_weave.ink.json";
    const text = try replay_fixture(gpa, fixture, "play");
    defer gpa.free(text);
    try std.testing.expect(heuristic_totals.divert_ancestor_of_choice_source > before);
}
