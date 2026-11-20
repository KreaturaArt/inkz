//! Differential fuzz target for save and load. A generated story plays to a
//! fuzzer-chosen point and is saved; a fresh story loads the save. The loaded story saves the
//! same JSON, and when the play ended cleanly (and no invisible default choice is pending),
//! both play on the same choices to the same transcript. A save mutated at the
//! token level loads into a state that checks, or fails and leaves the state as it was.

const std = @import("std");
const assert = std.debug.assert;
const Smith = std.testing.Smith;
const fuzz_ink = @import("../testing/fuzz_ink.zig");
const play = @import("play.zig");
const json_target = @import("json.zig");

const Allocator = std.mem.Allocator;
const script_max = 64;
const transcript_bytes_max = 64 * 1024;

/// Plays `script` (each byte picks among the current choices) and writes what the story shows:
/// each line, then each choice's text. Stops at the story's end or a failed call.
fn play_scripted(story: *play.Story, script: []const u8, transcript: *std.Io.Writer) void {
    assert(script.len <= script_max);
    var at: u32 = 0;
    var steps: u32 = 0;
    while (steps < play.steps_max) : (steps += 1) {
        if (story.can_continue()) {
            const line = story.cont() catch return;
            transcript.print("{s}", .{line.get()}) catch return;
            continue;
        }
        const count = story.current_choices_count();
        if (count == 0 or at == script.len) return;
        for (0..count) |position| {
            const choice = (story.current_choice(@intCast(position)) catch return).get();
            transcript.print("* {s}\n", .{choice.text}) catch return;
        }
        story.choose_choice_index(script[at] % count) catch return;
        at += 1;
    }
    assert(steps <= play.steps_max);
}

fn save_of(gpa: Allocator, story: *play.Story) ![]u8 {
    assert(story.core.state.check() == .ok);
    var save: std.Io.Writer.Allocating = .init(gpa);
    errdefer save.deinit();
    try story.to_json(&save.writer);
    return save.toOwnedSlice();
}

fn save_load(_: void, smith: *Smith) anyerror!void {
    _ = try check_save_load(.{ .smith = smith }, smith);
}

/// Plays, saves, loads and compares; then loads a mutated save when there is a Smith.
fn check_save_load(choices: fuzz_ink.Choices, smith: ?*Smith) !bool {
    const gpa = std.testing.allocator;
    var buffer: [fuzz_ink.source_bytes_max]u8 = undefined;
    var program = try play.compile_story(gpa, choices, &buffer) orelse return false;
    defer program.deinit(gpa);
    assert(program.check() == .ok);
    const setup: play.Setup = .pick(choices);
    var original: play.Story = undefined;
    try play.init_story(&original, gpa, &program, setup);
    defer original.deinit(gpa);
    const clean = play.play(&original, choices, @intCast(choices.below(play.steps_max)));
    // A story that failed in the middle of a step is half done and doesn't save.
    if (original.core.failed) return true;
    const save = try save_of(gpa, &original);
    defer gpa.free(save);

    var loaded: play.Story = undefined;
    try play.init_story(&loaded, gpa, &program, setup);
    defer loaded.deinit(gpa);
    try loaded.load_json(save);
    assert(loaded.core.state.check() == .ok);
    const save_again = try save_of(gpa, &loaded);
    defer gpa.free(save_again);
    assert(std.mem.eql(u8, save, save_again));

    // After a failed call the original isn't resumable, so only a clean play is compared.
    // ink's save doesn't keep a choice's isInvisibleDefault (JsonSerialisation's
    // JObjectToChoice), so a loaded fallback choice is visible, in ink and here: a save with
    // one isn't compared either.
    const all_choices = original.core.state.choices.records.slice().len;
    const invisible = all_choices > original.current_choices_count();
    var script: [script_max]u8 = undefined;
    for (&script) |*byte| byte.* = choices.choose(u8);
    if (clean and !invisible) try expect_same_play(&original, &loaded, &script);
    if (smith) |fuzzer| {
        _ = try load_mutated(.{ .smith = fuzzer }, gpa, &program, setup, save, null);
    }
    return true;
}

fn expect_same_play(original: *play.Story, loaded: *play.Story, script: []const u8) !void {
    assert(script.len == script_max);
    const gpa = std.testing.allocator;
    const first = try gpa.alloc(u8, transcript_bytes_max);
    defer gpa.free(first);
    const second = try gpa.alloc(u8, transcript_bytes_max);
    defer gpa.free(second);
    var first_writer: std.Io.Writer = .fixed(first);
    var second_writer: std.Io.Writer = .fixed(second);
    play_scripted(original, script, &first_writer);
    play_scripted(loaded, script, &second_writer);
    assert(first_writer.end <= transcript_bytes_max);
    assert(second_writer.end <= transcript_bytes_max);
    try std.testing.expectEqualStrings(first_writer.buffered(), second_writer.buffered());
}

/// A save edited with the JSON target's operators (drawn when `allowed` is null), loaded
/// into a fresh story: it loads and checks, or fails and leaves the story unchanged.
/// Returns the operators applied.
fn load_mutated(
    choices: fuzz_ink.Choices,
    gpa: Allocator,
    program: *const @import("../core/program.zig").Program,
    setup: play.Setup,
    save: []const u8,
    allowed: ?json_target.Mutations,
) !json_target.Mutations {
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(gpa);
    try json.appendSlice(gpa, save);
    const applied = try json_target.mutate_all(choices, gpa, &json, allowed, 4);
    var story: play.Story = undefined;
    try play.init_story(&story, gpa, program, setup);
    defer story.deinit(gpa);
    const before = story.core.state.hash();
    story.load_json(json.items) catch {
        assert(story.core.state.hash() == before);
        return applied;
    };
    assert(story.core.state.check() == .ok);
    _ = play.play(&story, choices, 32);
    return applied;
}

test "fuzz: a loaded save plays as the story it was saved from" {
    // Seeded stories first: most compile, and every one saves and loads to the same play.
    var compared: u32 = 0;
    for (0..32) |seed| {
        var prng: std.Random.DefaultPrng = .init(seed);
        if (try check_save_load(.{ .random = prng.random() }, null)) compared += 1;
    }
    try std.testing.expect(compared > 16);
    try std.testing.fuzz({}, save_load, .{ .corpus = &.{""} });
}

test "fuzz: an edited save applies only the operators it drew" {
    // A seeded story's save, edited 1,000 times: the operators applied are in the drawn
    // set; then each operator alone, on 8 seeds, loads cleanly or leaves the story as it was.
    const gpa = std.testing.allocator;
    var buffer: [fuzz_ink.source_bytes_max]u8 = undefined;
    // The first seed whose story compiles.
    var prng: std.Random.DefaultPrng = undefined;
    var choices: fuzz_ink.Choices = undefined;
    var seed_first: u64 = 0;
    var program = while (seed_first < 64) : (seed_first += 1) {
        prng = .init(seed_first);
        choices = .{ .random = prng.random() };
        break (try play.compile_story(gpa, choices, &buffer)) orelse continue;
    } else return error.NoStory;
    defer program.deinit(gpa);
    const setup: play.Setup = .pick(choices);
    var story: play.Story = undefined;
    try play.init_story(&story, gpa, &program, setup);
    defer story.deinit(gpa);
    _ = play.play(&story, choices, 16);
    const save = try save_of(gpa, &story);
    defer gpa.free(save);
    for (0..1000) |seed| {
        var seeded: std.Random.DefaultPrng = .init(seed);
        var draw_prng = seeded;
        const draw: fuzz_ink.Choices = .{ .random = draw_prng.random() };
        const allowed = fuzz_ink.draw_subset(draw, json_target.Mutation);
        const edits: fuzz_ink.Choices = .{ .random = seeded.random() };
        const applied = try load_mutated(edits, gpa, &program, setup, save, null);
        try std.testing.expect(applied.subsetOf(allowed));
    }
    for (std.enums.values(json_target.Mutation)) |mutation| {
        for (0..8) |seed| {
            var seeded: std.Random.DefaultPrng = .init(seed);
            const only: json_target.Mutations = .initOne(mutation);
            const edits: fuzz_ink.Choices = .{ .random = seeded.random() };
            const applied = try load_mutated(edits, gpa, &program, setup, save, only);
            try std.testing.expect(applied.subsetOf(only));
        }
    }
}
