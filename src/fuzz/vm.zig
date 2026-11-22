//! Fuzz target for the VM: a generated story compiled and played, the fuzzer
//! picking the seed, the external's binding and every choice. The state checks after every
//! call; runtime errors go to a handler, and a run ends with the story, a named error or
//! the step budget.

const std = @import("std");
const assert = std.debug.assert;
const fuzz_ink = @import("../testing/fuzz_ink.zig");
const play = @import("play.zig");

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
    return true;
}

test "fuzz: playing generated stories keeps the state consistent" {
    // Seeded stories first: most compile and play.
    try fuzz_ink.run_target(check_play, 16);
}
