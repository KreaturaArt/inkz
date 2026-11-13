//! Fuzz target for the VM (plan P11.8): a generated story compiled and played, the fuzzer
//! picking the seed, the external's binding and every choice. The state checks after every
//! call; runtime errors go to a handler, and a run ends with the story, a named error or
//! the step budget.

const std = @import("std");
const assert = std.debug.assert;
const Smith = std.testing.Smith;
const fuzz_ink = @import("../testing/fuzz_ink.zig");
const play = @import("play.zig");

fn play_story(_: void, smith: *Smith) anyerror!void {
    _ = try check_play(.{ .smith = smith });
}

/// Compiles a generated story and plays it; whether it compiled.
fn check_play(choices: fuzz_ink.Choices) !bool {
    const gpa = std.testing.allocator;
    var buffer: [fuzz_ink.source_bytes_max]u8 = undefined;
    var program = try play.compile_story(gpa, choices, &buffer) orelse return false;
    defer program.deinit(gpa);
    assert(program.check() == .ok);
    var story: play.Story = undefined;
    try play.init_story(&story, gpa, &program, .pick(choices));
    defer story.deinit(gpa);
    assert(story.core.program == &program);
    _ = play.play(&story, choices, play.steps_max);
    assert(story.core.state.check() == .ok);
    assert(story.core.state.memory.len > 0);
    return true;
}

test "fuzz: playing generated stories keeps the state consistent" {
    // Seeded stories first: most compile and play.
    var played: u32 = 0;
    for (0..32) |seed| {
        var prng: std.Random.DefaultPrng = .init(seed);
        if (try check_play(.{ .random = prng.random() })) played += 1;
    }
    try std.testing.expect(played > 16);
    try std.testing.fuzz({}, play_story, .{ .corpus = &.{""} });
}
