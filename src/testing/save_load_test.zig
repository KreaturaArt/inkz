//! Saving and loading, beyond the ground-truth transcripts (whose C# saves the runtime
//! reproduces byte for byte):
//! - a save and load at every turn of every case doesn't change the play;
//! - every C# save recorded in the ground truth loads, and saves back to the same JSON;
//! - a corrupted save leaves the story as `reset_state` leaves it.

const std = @import("std");
const assert = std.debug.assert;
const ink_json = @import("../core/ink_json.zig");
const Program = @import("../core/program.zig").Program;
const story_module = @import("../runtime/story.zig");
const Story = story_module.Story;
const api = @import("../runtime/story.zig");
const save = @import("../runtime/save.zig");
const load = @import("../runtime/load.zig");
const cases = @import("cases.zig");
const support = @import("support.zig");

/// Plays up to 30 turns choosing the first choice, writing every line and choice count to
/// `transcript`; with `round_trip`, saves and loads into a fresh story before each choice.
fn play(
    gpa: std.mem.Allocator,
    program: *const Program,
    transcript: *std.Io.Writer,
    round_trip: bool,
    save_buffer: []u8,
) !void {
    var story: api.Story = undefined;
    try story.init(gpa, program, .{});
    defer story.deinit(gpa);
    support.quiet(&story);
    for (0..30) |_| {
        // A failed line ends the turn, as it would end the run.
        _ = support.play(&story, .{ .list = &.{} }, transcript) catch {};
        const count = story.current_choices_count();
        try transcript.print("[{d} choices]\n", .{count});
        if (count == 0) return;
        // ink doesn't save isInvisibleDefault, so a hidden fallback choice shows after a
        // load, in C# too; turns holding one aren't round-tripped.
        if (round_trip and !has_invisible_default(&story)) {
            var writer: std.Io.Writer = .fixed(save_buffer);
            try story.to_json(&writer);
            const json = writer.buffered();
            story.deinit(gpa);
            try story.init(gpa, program, .{});
            support.quiet(&story);
            try story.load_json(json);
            try std.testing.expectEqual(count, story.current_choices_count());
        }
        try story.choose_choice_index(0);
    }
}

fn has_invisible_default(story: *Story) bool {
    assert(story.state.choices.count() <= story.state.choices.records.capacity());
    for (story.state.choices.records.slice()) |choice| {
        if (choice.invisible_default) return true;
    }
    return false;
}

test "a save and load at every turn doesn't change the play" {
    // Save, load, continue gives the uninterrupted run, at every turn of every
    // ground-truth case. Play each case twice, once with a round trip per turn.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const save_buffer = try arena.alloc(u8, 1 << 20);
    var checked: u32 = 0;
    var programs: cases.Programs = try .init(arena, arena, io);
    const gpa = std.testing.allocator;
    while (try programs.next()) |case| {
        var plain: std.Io.Writer.Allocating = .init(arena);
        var tripped: std.Io.Writer.Allocating = .init(arena);
        play(gpa, &case.program, &plain.writer, false, save_buffer) catch continue;
        try play(gpa, &case.program, &tripped.writer, true, save_buffer);
        std.testing.expectEqualStrings(plain.written(), tripped.written()) catch |err| {
            std.debug.print("case {s}\n", .{case.id});
            return err;
        };
        checked += 1;
    }
    try std.testing.expect(checked > 150);
}

test "every C# save in the ground truth loads and saves back to the same JSON" {
    // Interop: load each recorded `save:` into a fresh
    // story of its case and save again; ink and this runtime write keys in the same order,
    // so the text must match exactly.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var checked: u32 = 0;
    for (try cases.ids(arena, io)) |id| {
        const expected = try cases.read_expected(arena, io, id);
        if (std.mem.indexOf(u8, expected, "save: ") == null) continue;
        var program = try cases.load_program(arena, arena, io, id);
        var lines = std.mem.splitScalar(u8, expected, '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "save: ")) continue;
            const saved = line["save: ".len..];
            var story: Story = undefined;
            try story.init(std.testing.allocator, &program, .{});
            defer story.deinit(std.testing.allocator);
            try load.load_json(&story, saved);
            var again: std.Io.Writer.Allocating = .init(arena);
            try save.to_json(&story, &again.writer);
            std.testing.expectEqualStrings(saved, again.written()) catch |err| {
                std.debug.print("case {s}\n", .{id});
                return err;
            };
            checked += 1;
        }
    }
    try std.testing.expect(checked >= 6);
}

test "a corrupted save leaves the story reset" {
    // Break a real save in several ways: each load, from the saved state, fails part way
    // or before it starts and leaves the state hash reset_state gives.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const path = cases.cases_directory ++ "/audit/save_choices_and_seed.ink.json";
    const json = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20));
    var program = try ink_json.load(arena, json);
    var story: Story = undefined;
    try story.init(std.testing.allocator, &program, .{});
    defer story.deinit(std.testing.allocator);
    story_module.set_random_seed(&story, 5);
    while (story.can_continue()) _ = try story.cont();
    var saved: std.Io.Writer.Allocating = .init(arena);
    try save.to_json(&story, &saved.writer);
    try story.choose_choice_index(1);
    while (story.can_continue()) _ = try story.cont();
    const before = story.state.hash();
    const good = saved.written();
    const bad_list = "\"roll\":{\"list\":{\"no.such\":1}},\"x\":";
    const broken = [_][]const u8{
        good[0 .. good.len / 2],
        try std.mem.replaceOwned(u8, arena, good, "\"turnIdx\":", "\"turnIdx\":\"x\","),
        try std.mem.replaceOwned(u8, arena, good, "\"0.c-0\"", "\"nowhere\""),
        try std.mem.replaceOwned(u8, arena, good, "\"inkSaveVersion\":10", "\"inkSaveVersion\":7"),
        try std.mem.replaceOwned(u8, arena, good, "\"roll\":", bad_list),
        try std.mem.replaceOwned(u8, arena, good, "\"evalStack\":[]", "\"evalStack\":[\"bad\"]"),
    };
    for (broken) |text| {
        try load.load_json(&story, good);
        const loaded = story.state.hash();
        try std.testing.expect(loaded != before);
        try expect_reset_after(&story, load.load_json(&story, text));
        try std.testing.expect(story.state.hash() != loaded);
    }
}

/// Expects `result` to be a failed load that left `story` as `reset_state` leaves it.
fn expect_reset_after(story: *Story, result: load.Error!void) !void {
    if (result) |_| return error.TestUnexpectedResult else |_| {}
    const after = story.state.hash();
    try story.reset_state();
    try std.testing.expectEqual(after, story.state.hash());
}

test "a cont that fails in the newline lookahead leaves a state that saves" {
    // Found by the save fuzz target: a limit error inside the lookahead after a
    // newline left the snapshot active, and saving then asserted. A function that
    // recurses past frames_max right after the first line; cont fails, then the story saves,
    // and the save loads into a fresh story.
    const gpa = std.testing.allocator;
    const compile = @import("../compiler/compile.zig");
    const source =
        \\Hello
        \\{f(1)}
        \\=== function f(x) ===
        \\~ return f(x + 1)
        \\
    ;
    var program = try compile.compile_source(gpa, source);
    defer program.deinit(gpa);
    const limits: @import("../core/limits.zig").Limits = .{
        .frames_max = 16,
        .threads_max = 4,
        .evaluate_depth_max = 4,
    };
    var story: Story = undefined;
    try story.init(gpa, &program, .{ .limits = limits });
    defer story.deinit(gpa);
    story.on_error = support.ignore_message;
    try std.testing.expectError(error.FrameLimit, story.cont());
    try std.testing.expect(story.state.check() == .ok);
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try save.to_json(&story, &writer);
    var loaded: Story = undefined;
    try loaded.init(gpa, &program, .{ .limits = limits });
    defer loaded.deinit(gpa);
    try load.load_json(&loaded, writer.buffered());
    try std.testing.expect(loaded.state.check() == .ok);
}

test "a cont that fails in the newline lookahead leaves no divert pending" {
    // P18.5, found by the swarm's host target: a call to a function sets the pending divert
    // before the frame push that fails at frames_max, and the lookahead's restore kept it,
    // so choose_path_string asserted that none was pending. A function that recurses past
    // frames_max right after the first line; cont fails, back at the end of that line, and
    // the story chooses a knot and plays it.
    const gpa = std.testing.allocator;
    const compile = @import("../compiler/compile.zig");
    const source =
        \\Hello
        \\{f(1)}
        \\=== k ===
        \\There.
        \\-> END
        \\=== function f(x) ===
        \\~ return f(x + 1)
        \\
    ;
    var program = try compile.compile_source(gpa, source);
    defer program.deinit(gpa);
    const limits: @import("../core/limits.zig").Limits = .{
        .frames_max = 16,
        .threads_max = 4,
        .evaluate_depth_max = 4,
    };
    var story: Story = undefined;
    try story.init(gpa, &program, .{ .limits = limits });
    defer story.deinit(gpa);
    story.on_error = support.ignore_message;
    try std.testing.expectError(error.FrameLimit, story.cont());
    try std.testing.expect(story.diverted_pointer.is_null());
    try story.choose_path_string("k", .{});
    try std.testing.expectEqualStrings("There.\n", (try story.cont()).get());
    try std.testing.expect(story.state.check() == .ok);
}

test "a cont that fails in the middle of a step fails closed until reset or load" {
    // Found by the host API fuzz target: after a limit error in the middle of a
    // step, the next cont ran on from the half-done state and asserted. A function
    // recursing past frames_max inside a string evaluation, before any newline; then every
    // continuing call returns StoryFailed until reset_state, and a save made before loads.
    const gpa = std.testing.allocator;
    const compile = @import("../compiler/compile.zig");
    const source =
        \\Before {"a{f(1)}"}
        \\=== function f(x) ===
        \\~ return f(x + 1)
        \\
    ;
    var program = try compile.compile_source(gpa, source);
    defer program.deinit(gpa);
    const limits: @import("../core/limits.zig").Limits = .{
        .frames_max = 16,
        .threads_max = 4,
        .evaluate_depth_max = 4,
    };
    var story: Story = undefined;
    try story.init(gpa, &program, .{ .limits = limits });
    defer story.deinit(gpa);
    story.on_error = support.ignore_message;
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try save.to_json(&story, &writer);
    try std.testing.expectError(error.FrameLimit, story.cont());
    try std.testing.expect(!story.can_continue());
    try std.testing.expectError(error.StoryFailed, story.cont());
    try std.testing.expectEqual(@as(u32, 0), story.current_choices_count());
    try std.testing.expectError(error.StoryFailed, story.choose_choice_index(0));
    try load.load_json(&story, writer.buffered());
    try std.testing.expect(story.can_continue());
    try std.testing.expectError(error.FrameLimit, story.cont());
    try story.reset_state();
    try std.testing.expect(story.can_continue());
    try std.testing.expect(story.state.check() == .ok);
}

test "a step budget that runs out in the newline lookahead leaves a state that saves" {
    // StepLimit takes the same way out as the other limit errors: a
    // divert loop right after the first line, with a small steps_per_continue_max.
    const gpa = std.testing.allocator;
    const compile = @import("../compiler/compile.zig");
    const source =
        \\Hello
        \\-> loop
        \\=== loop ===
        \\-> loop
        \\
    ;
    var program = try compile.compile_source(gpa, source);
    defer program.deinit(gpa);
    var story: Story = undefined;
    try story.init(gpa, &program, .{ .limits = .{ .steps_per_continue_max = 100 } });
    defer story.deinit(gpa);
    try std.testing.expectError(error.StepLimit, story.cont());
    try std.testing.expect(!story.failed);
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try save.to_json(&story, &writer);
    try std.testing.expectError(error.StepLimit, story.cont());
    try std.testing.expect(story.state.check() == .ok);
}

/// A tunnel with a reference parameter, waiting at a choice: its frame holds `r`, a
/// variable pointer to the caller's temp `x`.
const pointer_source =
    \\-> start
    \\== start ==
    \\~ temp x = 1
    \\-> tun(x) ->
    \\Done {x}.
    \\-> END
    \\== tun(ref r) ==
    \\* [Go]
    \\~ r = 2
    \\->->
    \\
;

/// Expects `json` to fail to load with `expected`, leaving `story` reset.
fn expect_load_error(story: *Story, json: []const u8, expected: load.Error) !void {
    const result = load.load_json(story, json);
    try std.testing.expectError(expected, result);
    try expect_reset_after(story, result);
}

test "a save's flows must include the default flow, each name once" {
    // Found in review: a lone non-default flow loaded and then to_json asserted on the
    // default flow's empty parking, and a repeated flow name parked one record twice. ink
    // writes the default flow in every save, so both are InvalidSave; the story is reset
    // and the real save (two flows) still loads and saves back the same.
    const gpa = std.testing.allocator;
    const compile = @import("../compiler/compile.zig");
    var program = try compile.compile_source(gpa, pointer_source);
    defer program.deinit(gpa);
    var story: Story = undefined;
    try story.init(gpa, &program, .{});
    defer story.deinit(gpa);
    support.quiet(&story);
    var single: std.Io.Writer.Allocating = .init(gpa);
    defer single.deinit();
    try save.to_json(&story, &single.writer);
    const lone = try std.mem.replaceOwned(u8, gpa, single.written(), "DEFAULT_FLOW", "a");
    defer gpa.free(lone);
    try expect_load_error(&story, lone, error.InvalidSave);
    try story.switch_flow("side");
    while (story.can_continue()) _ = try story.cont();
    try story.switch_to_default_flow();
    var both: std.Io.Writer.Allocating = .init(gpa);
    defer both.deinit();
    try save.to_json(&story, &both.writer);
    const renamed = "\"DEFAULT_FLOW\":{";
    const twice = try std.mem.replaceOwned(u8, gpa, both.written(), "\"side\":{", renamed);
    defer gpa.free(twice);
    try expect_load_error(&story, twice, error.InvalidSave);
    try load.load_json(&story, both.written());
    var again: std.Io.Writer.Allocating = .init(gpa);
    defer again.deinit();
    try save.to_json(&story, &again.writer);
    try std.testing.expectEqualStrings(both.written(), again.written());
}

test "a saved variable pointer's context is checked on load and when followed" {
    // Found in review: a pointer's "ci" from a save reached the VM unchecked. Below -1 is
    // InvalidSave; a frame deeper than the call stack loads (ink only finds out when it
    // follows it) and assigning through it is a story error, not an assertion.
    const gpa = std.testing.allocator;
    const compile = @import("../compiler/compile.zig");
    var program = try compile.compile_source(gpa, pointer_source);
    defer program.deinit(gpa);
    var story: Story = undefined;
    try story.init(gpa, &program, .{});
    defer story.deinit(gpa);
    support.quiet(&story);
    while (story.can_continue()) _ = try story.cont();
    try std.testing.expectEqual(@as(u32, 1), story.current_choices_count());
    var saved: std.Io.Writer.Allocating = .init(gpa);
    defer saved.deinit();
    try save.to_json(&story, &saved.writer);
    const good = saved.written();
    try std.testing.expect(std.mem.indexOf(u8, good, "\"ci\":1") != null);
    const below = try std.mem.replaceOwned(u8, gpa, good, "\"ci\":1", "\"ci\":-2");
    defer gpa.free(below);
    try expect_load_error(&story, below, error.InvalidSave);
    const deep = try std.mem.replaceOwned(u8, gpa, good, "\"ci\":1", "\"ci\":7");
    defer gpa.free(deep);
    try load.load_json(&story, deep);
    try story.choose_choice_index(0);
    story.on_error = null; // Without a handler, cont returns the story error.
    try std.testing.expectError(error.StoryError, story.cont());
    try std.testing.expect(story.state.check() == .ok);
    story.state.reset_errors(); // Unhandled errors stay until reset, as in ink.
    support.quiet(&story);
    try load.load_json(&story, good);
    try story.choose_choice_index(0);
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    while (story.can_continue()) try text.writer.writeAll((try story.cont()).get());
    try std.testing.expectEqualStrings("Done 2.\n", text.written());
}
