const std = @import("std");
const ink_json = @import("core/ink_json.zig");
const limits_module = @import("core/limits.zig");
const Limits = limits_module.Limits;
const Story = @import("runtime/story.zig").Story;
const State = @import("runtime/state.zig").State;
const DotnetRandom = @import("core/dotnet_random.zig").DotnetRandom;
const CountingAllocator = @import("core/counting_allocator.zig").CountingAllocator;
const Severity = @import("runtime/state.zig").Diagnostic.Severity;
fn ignore(_: ?*anyopaque, _: []const u8, _: Severity) void {}

fn scaled(base: Limits, num: u32, den: u32) Limits {
    var l = base;
    inline for (@typeInfo(Limits).@"struct".field_names) |n| {
        if (comptime std.mem.eql(u8, n, "steps_per_continue_max")) continue;
        @field(l, n) = @max(1, @field(base, n) / den * num);
    }
    l.heap_bytes_max -= l.heap_bytes_max % 4;
    l.flow_parking_bytes_max -= l.flow_parking_bytes_max % 4;
    return l;
}

fn now(io: std.Io) std.Io.Timestamp { return std.Io.Timestamp.now(io, .awake); }
fn us(io: std.Io, t: std.Io.Timestamp) f64 { return @as(f64, @floatFromInt(t.durationTo(now(io)).toNanoseconds())) / 1000.0; }

fn play(story: *Story, plays: u32) !u64 {
    var turns: u64 = 0;
    for (0..plays) |p| {
        try story.reset_state();
        var random = DotnetRandom.init(@intCast(p % 200 + 1));
        var turn: u32 = 0;
        while (turn < 200) : (turn += 1) {
            while (story.can_continue()) _ = try story.cont();
            const n = story.visible_choices_count();
            if (n == 0) break;
            try story.choose_choice_index(@intCast(@mod(random.next(), @as(i32, @intCast(n)))));
        }
        turns += turn;
    }
    return turns;
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    const io = init.io;
    const configs = [_]struct { name: []const u8, limits: Limits }{
        .{ .name = "x4", .limits = scaled(.{}, 4, 1) },
        .{ .name = "default", .limits = .{} },
        .{ .name = "half", .limits = scaled(.{}, 1, 2) },
        .{ .name = "small_story", .limits = limits_module.small_story_limits },
        .{ .name = "eighth", .limits = scaled(.{}, 1, 8) },
        .{ .name = "32nd", .limits = scaled(.{}, 1, 32) },
        .{ .name = "32nd+choices", .limits = blk: { var l = scaled(.{}, 1, 32); l.choices_max = 16; l.choice_snapshot_frames_max = 64; break :blk l; } },
        .{ .name = "64th+choices", .limits = blk: { var l = scaled(.{}, 1, 64); l.choices_max = 16; l.choice_snapshot_frames_max = 64; l.frames_max = 64; break :blk l; } },
    };
    for ([_][]const u8{ "test/ground_truth/crime_scene.ink.json", "test/fixture/bench/generated.ink.json" }) |path| {
        const json = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 24));
        var counting = CountingAllocator.init(gpa);
        var program = try ink_json.load(counting.allocator(), json);
        const program_bytes = counting.bytes_live;
        var t = now(io);
        for (0..200) |_| { var p = try ink_json.load(gpa, json); p.deinit(gpa); }
        const json_us = us(io, t) / 200;
        std.debug.print("{s}: program {d} B, ink_json.load {d:.0} us\n", .{ path, program_bytes, json_us });
        for (configs) |config| {
            if (config.limits.check() != .ok) { std.debug.print("  {s}: invalid {t}\n", .{config.name, config.limits.check()}); continue; }
            const bytes = config.limits.bytes_total(State.shape_of(&program));
            t = now(io);
            for (0..200) |_| { var s: Story = undefined; try s.init(gpa, &program, config.limits); s.deinit(gpa); }
            const init_us = us(io, t) / 200;
            var story: Story = undefined;
            try story.init(gpa, &program, config.limits);
            defer story.deinit(gpa);
            story.on_error = ignore;
            t = now(io);
            const turns = play(&story, 200) catch |err| { std.debug.print("  {s}: state {d} B, init {d:.0} us, play failed {t}\n", .{ config.name, bytes, init_us, err }); continue; };
            const sec = us(io, t) / 1e6;
            t = now(io);
            for (0..200) |_| try story.reset_state();
            const reset_us = us(io, t) / 200;
            std.debug.print("  {s}: state {d} B, init {d:.0} us, reset {d:.1} us, {d:.0} turns/s\n", .{ config.name, bytes, init_us, reset_us, @as(f64, @floatFromInt(turns)) / sec });
        }
        program.deinit(counting.allocator());
    }
}
