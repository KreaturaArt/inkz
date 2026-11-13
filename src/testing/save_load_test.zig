//! Saving and loading, beyond the ground-truth transcripts (whose C# saves the runtime
//! reproduces byte for byte):
//! - a save and load at every turn of every case doesn't change the play;
//! - every C# save recorded in the ground truth loads, and saves back to the same JSON;
//! - a corrupted save leaves the story unchanged.

const std = @import("std");
const assert = std.debug.assert;
const ink_json = @import("../core/ink_json.zig");
const Program = @import("../core/program.zig").Program;
const Story = @import("../runtime/story.zig").Story;
const save = @import("../runtime/save.zig");
const load = @import("../runtime/load.zig");
const cases = @import("cases.zig");
const support = @import("support.zig");

fn prepare(story: *Story) void {
    assert(story.callback_depth == 0);
    assert(story.state.memory.len > 0);
    support.quiet(story);
}

/// Plays up to `turns` turns choosing the first choice, writing every line and choice to
/// `transcript`; with `round_trip`, saves and loads into a fresh story before each choice.
fn play(
    gpa: std.mem.Allocator,
    program: *const Program,
    transcript: *std.Io.Writer,
    round_trip: bool,
    save_buffer: []u8,
) !void {
    assert(save_buffer.len > 0);
    assert(program.containers.len > 0);
    var story: Story = undefined;
    try story.init(gpa, program, .{});
    defer story.deinit(gpa);
    prepare(&story);
    var turn: u32 = 0;
    while (turn < 30) : (turn += 1) {
        var lines: u32 = 0;
        while (story.can_continue() and lines < 300) : (lines += 1) {
            const line = story.cont() catch break;
            try transcript.writeAll(line);
        }
        const count = story.visible_choices_count();
        try transcript.print("[{d} choices]\n", .{count});
        if (count == 0) return;
        // ink doesn't save isInvisibleDefault, so a hidden fallback choice shows after a
        // load, in C# too; turns holding one aren't round-tripped.
        if (round_trip and !has_invisible_default(&story)) {
            var writer: std.Io.Writer = .fixed(save_buffer);
            try save.to_json(&story, &writer);
            const json = writer.buffered();
            story.deinit(gpa);
            try story.init(gpa, program, .{});
            prepare(&story);
            try load.load_json(&story, json);
            try std.testing.expectEqual(count, story.visible_choices_count());
        }
        try story.choose_choice_index(0);
    }
}

fn has_invisible_default(story: *Story) bool {
    assert(story.state.memory.len > 0);
    assert(story.state.choices.count() <= story.state.choices.records.capacity());
    for (story.state.choices.records.slice()) |choice| {
        if (choice.invisible_default) return true;
    }
    return false;
}

test "a save and load at every turn doesn't change the play" {
    // Goal: P6.2; save, load, continue gives the uninterrupted run, at every turn of every
    // ground-truth case. Method: play each case twice, once with a round trip per turn.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const save_buffer = try arena.alloc(u8, 1 << 20);
    var checked: u32 = 0;
    for (try cases.ids(arena, io)) |id| {
        const path = try std.fmt.allocPrint(arena, "{s}/{s}.ink.json", .{
            cases.cases_directory,
            id,
        });
        const json = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 << 20));
        var program = ink_json.load(arena, json) catch continue;
        var plain: std.Io.Writer.Allocating = .init(arena);
        var tripped: std.Io.Writer.Allocating = .init(arena);
        play(std.testing.allocator, &program, &plain.writer, false, save_buffer) catch continue;
        try play(std.testing.allocator, &program, &tripped.writer, true, save_buffer);
        std.testing.expectEqualStrings(plain.written(), tripped.written()) catch |err| {
            std.debug.print("case {s}\n", .{id});
            return err;
        };
        checked += 1;
    }
    try std.testing.expect(checked > 150);
}

test "every C# save in the ground truth loads and saves back to the same JSON" {
    // Goal: P6.1 and P6.2 interop (D15). Method: load each recorded `save:` into a fresh
    // story of its case and save again; ink and this runtime write keys in the same order,
    // so the text must match exactly.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var checked: u32 = 0;
    for (try cases.ids(arena, io)) |id| {
        const expected_path = try std.fmt.allocPrint(arena, "{s}/{s}.expected", .{
            cases.cases_directory,
            id,
        });
        const expected = try std.Io.Dir.cwd().readFileAlloc(
            io,
            expected_path,
            arena,
            .limited(16 << 20),
        );
        if (std.mem.indexOf(u8, expected, "\nsave: ") == null) continue;
        const path = try std.fmt.allocPrint(arena, "{s}/{s}.ink.json", .{
            cases.cases_directory,
            id,
        });
        const json = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 << 20));
        var program = try ink_json.load(arena, json);
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

test "a corrupted save leaves the story unchanged" {
    // Goal: P6.2 validate-then-commit. Method: break a real save in several ways; each load
    // fails and the state hash doesn't move.
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
    story.set_random_seed(5);
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
        if (load.load_json(&story, text)) |_| return error.TestUnexpectedResult else |_| {}
        try std.testing.expectEqual(before, story.state.hash());
    }
    try load.load_json(&story, good);
    try std.testing.expect(story.state.hash() != before);
}

test "a cont that fails in the newline lookahead leaves a state that saves" {
    // Goal: found by the save fuzz target (P11.9): a limit error inside the lookahead after a
    // newline left the snapshot active, and saving then asserted. Method: a function that
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
    try story.init(gpa, &program, limits);
    defer story.deinit(gpa);
    story.on_error = support.ignore_message;
    try std.testing.expectError(error.FrameLimit, story.cont());
    try std.testing.expect(story.state.check() == .ok);
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try save.to_json(&story, &writer);
    var loaded: Story = undefined;
    try loaded.init(gpa, &program, limits);
    defer loaded.deinit(gpa);
    try load.load_json(&loaded, writer.buffered());
    try std.testing.expect(loaded.state.check() == .ok);
}

test "a cont that fails in the middle of a step fails closed until reset or load" {
    // Goal: found by the host API fuzz target (P11.10): after a limit error in the middle of a
    // step, the next cont ran on from the half-done state and asserted. Method: a function
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
    try story.init(gpa, &program, limits);
    defer story.deinit(gpa);
    story.on_error = support.ignore_message;
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try save.to_json(&story, &writer);
    try std.testing.expectError(error.FrameLimit, story.cont());
    try std.testing.expect(!story.can_continue());
    try std.testing.expectError(error.StoryFailed, story.cont());
    try std.testing.expectEqual(@as(u32, 0), story.visible_choices_count());
    try std.testing.expectError(error.StoryFailed, story.choose_choice_index(0));
    try load.load_json(&story, writer.buffered());
    try std.testing.expect(story.can_continue());
    try std.testing.expectError(error.FrameLimit, story.cont());
    try story.reset_state();
    try std.testing.expect(story.can_continue());
    try std.testing.expect(story.state.check() == .ok);
}

test "a step budget that runs out in the newline lookahead leaves a state that saves" {
    // Goal: StepLimit takes the same way out as the other limit errors (P11.9). Method: a
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
    try story.init(gpa, &program, .{ .steps_per_continue_max = 100 });
    defer story.deinit(gpa);
    try std.testing.expectError(error.StepLimit, story.cont());
    try std.testing.expect(!story.failed);
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try save.to_json(&story, &writer);
    try std.testing.expectError(error.StepLimit, story.cont());
    try std.testing.expect(story.state.check() == .ok);
}
