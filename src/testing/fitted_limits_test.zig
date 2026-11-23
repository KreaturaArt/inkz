//! Fitted limits: a story's measured usage, fitted with a margin, plays the story the
//! same in a fraction of the default budget.

const std = @import("std");
const assert = std.debug.assert;
const ink_json = @import("../core/ink_json.zig");
const limits_module = @import("../core/limits.zig");
const Program = @import("../core/program.zig").Program;
const api = @import("../runtime/story.zig");
const State = @import("../runtime/state.zig").State;
const cases = @import("cases.zig");
const support = @import("support.zig");

/// Plays seeds 1..`seeds` with seeded choices and returns all text.
fn play(gpa: std.mem.Allocator, story: *api.Story, seeds: u32) ![]u8 {
    assert(seeds > 0);
    var text: std.Io.Writer.Allocating = .init(gpa);
    errdefer text.deinit();
    for (1..seeds + 1) |seed| {
        try story.reset_state();
        _ = try support.play(story, .{ .seeded = @intCast(seed) }, &text.writer);
    }
    return text.toOwnedSlice();
}

test "fitted limits play crime_scene the same in under 64 KiB" {
    // Play 50 seeds with the default limits and read the usage; fit
    // it with margin 2; the same seeds within the fitted limits give the same text.
    const gpa = std.testing.allocator;
    const path = cases.cases_directory ++ "/crime_scene.ink.json";
    const json = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .limited(1 << 20));
    defer gpa.free(json);
    var program = try ink_json.load(gpa, json);
    defer program.deinit(gpa);
    var measured: api.Story = undefined;
    try measured.init(gpa, &program, .{ .on_error = support.ignore_message });
    defer measured.deinit(gpa);
    const expected = try play(gpa, &measured, 50);
    defer gpa.free(expected);
    const usage = measured.usage();
    try std.testing.expect(usage.frames > 0 and usage.choices > 0 and usage.output_items > 0);
    try std.testing.expect(usage.frames <= measured.state.limits.frames_max);
    const limits = limits_module.fitted(usage, 2);
    try std.testing.expect(limits.bytes_total(State.shape_of(&program)) < 64 * 1024);
    var fitted: api.Story = undefined;
    try fitted.init(gpa, &program, .{ .limits = limits, .on_error = support.ignore_message });
    defer fitted.deinit(gpa);
    const actual = try play(gpa, &fitted, 50);
    defer gpa.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}
