const std = @import("std");
const ink_json = @import("core/ink_json.zig");
const Story = @import("runtime/story.zig").Story;
const DotnetRandom = @import("core/dotnet_random.zig").DotnetRandom;
const Severity = @import("runtime/state.zig").Diagnostic.Severity;
fn ignore(_: ?*anyopaque, _: []const u8, _: Severity) void {}
pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const path = args[1];
    const mode = args[2];
    const json = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 24));
    if (std.mem.eql(u8, mode, "load")) {
        for (0..20000) |_| {
            var p = try ink_json.load(gpa, json);
            var s: Story = undefined;
            try s.init(gpa, &p, .{});
            s.deinit(gpa);
            p.deinit(gpa);
        }
        return;
    }
    var program = try ink_json.load(gpa, json);
    var story: Story = undefined;
    try story.init(gpa, &program, .{});
    story.on_error = ignore;
    for (0..20000) |play| {
        try story.reset_state();
        var random = DotnetRandom.init(@intCast(play % 200 + 1));
        var turn: u32 = 0;
        while (turn < 200) : (turn += 1) {
            while (story.can_continue()) _ = try story.cont();
            const n = story.visible_choices_count();
            if (n == 0) break;
            try story.choose_choice_index(@intCast(@mod(random.next(), @as(i32, @intCast(n)))));
        }
    }
}
