//! Fitted limits (P10.2): a story's measured usage, fitted with a margin, plays the story the
//! same in a fraction of the default budget.

const std = @import("std");
const assert = std.debug.assert;
const ink_json = @import("../core/ink_json.zig");
const limits_module = @import("../core/limits.zig");
const Program = @import("../core/program.zig").Program;
const Story = @import("../runtime/story.zig").Story;
const State = @import("../runtime/state.zig").State;
const DotnetRandom = @import("../core/dotnet_random.zig").DotnetRandom;
const cases = @import("cases.zig");
const support = @import("support.zig");

/// Plays seeds 1..`seeds` with random choices and returns all text.
fn play(gpa: std.mem.Allocator, story: *Story, seeds: u32) ![]u8 {
    assert(seeds > 0);
    story.on_error = support.ignore_message;
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    for (1..seeds + 1) |seed| {
        try story.reset_state();
        var random = DotnetRandom.init(@intCast(seed));
        for (0..100) |_| {
            while (story.can_continue()) try text.appendSlice(gpa, try story.cont());
            const count = story.visible_choices_count();
            if (count == 0) break;
            const index = @mod(random.next(), @as(i32, @intCast(count)));
            try story.choose_choice_index(@intCast(index));
        }
    }
    assert(text.items.len > 0);
    return text.toOwnedSlice(gpa);
}

test "fitted limits play crime_scene the same in under 64 KiB" {
    // Goal: P10.2. Method: play 50 seeds with the default limits and read the usage; fit
    // it with margin 2; the same seeds within the fitted limits give the same text.
    const gpa = std.testing.allocator;
    const path = cases.cases_directory ++ "/crime_scene.ink.json";
    const json = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .limited(1 << 20));
    defer gpa.free(json);
    var program = try ink_json.load(gpa, json);
    defer program.deinit(gpa);
    var measured: Story = undefined;
    try measured.init(gpa, &program, .{});
    defer measured.deinit(gpa);
    const expected = try play(gpa, &measured, 50);
    defer gpa.free(expected);
    const usage = measured.usage();
    try std.testing.expect(usage.frames > 0 and usage.choices > 0 and usage.output_items > 0);
    try std.testing.expect(usage.frames <= measured.state.limits.frames_max);
    const limits = limits_module.fitted(usage, 2);
    try std.testing.expect(limits.bytes_total(State.shape_of(&program)) < 64 * 1024);
    var fitted: Story = undefined;
    try fitted.init(gpa, &program, limits);
    defer fitted.deinit(gpa);
    const actual = try play(gpa, &fitted, 50);
    defer gpa.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}
