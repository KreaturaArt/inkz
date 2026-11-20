//! The deterministic story simulator, run with `zig build simulate`: each ground-truth case
//! played with seeded random choices and the full action mix (save and load points, flow
//! switches, `evaluate_function`, `set_variable`, compact-always), with `State.check()` after
//! every `cont()`. A run depends only on its case and seed, so every report carries the
//! command that reproduces it.

const std = @import("std");
const assert = std.debug.assert;
const isolated = @import("isolated.zig");
const cases = @import("cases.zig");
const support = @import("support.zig");

/// Plays case `id` with choices from `new Random(seed)` (`play_seeded`), in a child process.
pub fn run_seed(arena: std.mem.Allocator, io: std.Io, id: []const u8, seed: i32) !isolated.Run {
    const actions = try std.fmt.allocPrint(arena, "play_seeded {d}", .{seed});
    return isolated.replay(arena, io, &.{ id, "--actions", actions });
}

test "a simulation run is reproducible by seed" {
    // The same case and seed give the same run, and other seeds explore other paths.
    // Run a branching weave twice with one seed, then with others.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const id = "runtime/weaves/weave_gathers";
    const first = try run_seed(arena, io, id, 7);
    const again = try run_seed(arena, io, id, 7);
    try std.testing.expect(!first.crashed);
    try std.testing.expectEqualStrings(first.transcript, again.transcript);
    var differs = false;
    for ([_]i32{ 1, 2, 3, 4, 5, 6 }) |seed| {
        const other = try run_seed(arena, io, id, seed);
        differs = differs or !std.mem.eql(u8, other.transcript, first.transcript);
    }
    try std.testing.expect(differs);
}

const ink_json = @import("../core/ink_json.zig");
const Program = @import("../core/program.zig").Program;
const DotnetRandom = @import("../core/dotnet_random.zig").DotnetRandom;
const Story = @import("../runtime/story.zig").Story;
const state_module = @import("../runtime/state.zig");
const flows_module = @import("../runtime/flows.zig");
const save_module = @import("../runtime/save.zig");
const load_module = @import("../runtime/load.zig");
const evaluate_module = @import("../runtime/evaluate.zig");
const story_paths = @import("../runtime/story_paths.zig");

/// What a simulated run found.
pub const Finding = enum { ok, check_failed, round_trip_differs };

/// The simulator's action mix: how often each action runs after a turn's lines (weights out
/// of 100, rolled once per turn), and whether the heap compacts before every allocation.
/// `Mix.full` is the simulator's mix before swarms; `--swarm on` draws one per seed
/// (plan §3.5), so a seed with only flow switches, or without saves, gets dense coverage.
pub const Mix = struct {
    weights: std.EnumArray(Action, u8),
    compact_always: bool,

    pub const Action = enum { round_trip, switch_flow, set_variable, evaluate, choose_path };

    pub const full: Mix = .{
        .weights = .init(.{
            .round_trip = 15,
            .switch_flow = 10,
            .set_variable = 10,
            .evaluate = 5,
            .choose_path = 0,
        }),
        .compact_always = false,
    };

    /// Each action on with probability ½ and a weight of 1 to 20, from `new Random(seed)`
    /// offset so that the draw doesn't repeat the choices' sequence.
    pub fn draw(seed: i32) Mix {
        var random = DotnetRandom.init(seed +% 0x5eed);
        var mix: Mix = .{ .weights = .initFill(0), .compact_always = @rem(random.next(), 2) == 0 };
        for (std.enums.values(Action)) |action| {
            if (@rem(random.next(), 2) == 0) continue;
            mix.weights.set(action, @intCast(1 + @rem(random.next(), 20)));
        }
        assert(mix.total() <= 100);
        return mix;
    }

    fn total(mix: *const Mix) u32 {
        var sum: u32 = 0;
        for (mix.weights.values) |weight| sum += weight;
        return sum;
    }

    /// The action a roll of 0 to 99 picks, or null for none.
    fn pick(mix: *const Mix, roll: i32) ?Action {
        assert(roll >= 0 and roll < 100);
        var below: i32 = 0;
        for (std.enums.values(Action)) |action| {
            below += mix.weights.get(action);
            if (roll < below) return action;
        }
        return null;
    }

    /// One number for `--swarm-config`: a byte per weight, then the compact flag.
    pub fn encode(mix: Mix) u64 {
        var code: u64 = @intFromBool(mix.compact_always);
        for (std.enums.values(Action), 0..) |action, index| {
            code |= @as(u64, mix.weights.get(action)) << @intCast(8 + 8 * index);
        }
        return code;
    }

    pub fn decode(code: u64) error{InvalidMix}!Mix {
        if (code >> 48 != 0 or code & 0xfe != 0) return error.InvalidMix;
        var mix: Mix = .{ .weights = .initFill(0), .compact_always = code & 1 == 1 };
        for (std.enums.values(Action), 0..) |action, index| {
            mix.weights.set(action, @truncate(code >> @intCast(8 + 8 * index)));
        }
        if (mix.total() > 100) return error.InvalidMix;
        return mix;
    }
};

/// Plays `story` with the full action mix driven by `new Random(seed)`: seeded
/// choices, save and load points, flow switches, evaluate_function on the story's knots,
/// set_variable, and State.check after every cont. `save_buffer` holds the saves.
pub fn simulate(story: *Story, seed: i32, save_buffer: []u8) !Finding {
    return simulate_mix(story, seed, .full, save_buffer, null);
}

/// `simulate` with the actions and weights of `mix`; `counts`, when given, counts the
/// actions taken.
pub fn simulate_mix(
    story: *Story,
    seed: i32,
    mix: Mix,
    save_buffer: []u8,
    counts: ?*std.EnumArray(Mix.Action, u32),
) !Finding {
    var random = DotnetRandom.init(seed);
    try story.reset_state();
    story.set_random_seed(seed);
    var turn: u32 = 0;
    while (turn < 50) : (turn += 1) {
        var lines: u32 = 0;
        while (story.can_continue() and lines < 300) : (lines += 1) {
            _ = story.cont() catch |err| switch (err) {
                error.StoryError, error.ExternalFunctionFailed => break,
                else => return err,
            };
            if (story.state.check() != .ok) return .check_failed;
        }
        const roll = @rem(random.next(), 100);
        if (mix.pick(roll)) |action| {
            if (counts) |counted| counted.getPtr(action).* += 1;
            switch (action) {
                .round_trip => if (!try round_trip(story, save_buffer)) {
                    return .round_trip_differs;
                },
                .switch_flow => try switch_and_back(story),
                .set_variable => try set_some_variable(story, &random),
                .evaluate => evaluate_some_knot(story, &random),
                .choose_path => choose_some_knot(story, &random),
            }
        }
        if (story.state.check() != .ok) return .check_failed;
        const count = story.visible_choices_count();
        if (count == 0) return .ok;
        const pick: u32 = @intCast(@rem(random.next(), @as(i32, @intCast(count))));
        try story.choose_choice_index(pick);
    }
    return .ok;
}

/// Saves, loads the save into the same story, and saves again: both saves must match.
fn round_trip(story: *Story, save_buffer: []u8) !bool {
    assert(!@import("../runtime/lookahead.zig").active(&story.state));
    assert(save_buffer.len % 2 == 0);
    const half = save_buffer.len / 2;
    var first: std.Io.Writer = .fixed(save_buffer[0..half]);
    save_module.to_json(story, &first) catch return true; // too big for the buffer
    load_module.load_json(story, first.buffered()) catch |err| switch (err) {
        error.SaveTooLarge => return true,
        else => {
            std.debug.print("load failed: {t}\nsave: {s}\n", .{ err, first.buffered() });
            return false;
        },
    };
    var second: std.Io.Writer = .fixed(save_buffer[half..]);
    save_module.to_json(story, &second) catch return false;
    const same = std.mem.eql(u8, first.buffered(), second.buffered());
    if (!same) std.debug.print("first:  {s}\nsecond: {s}\n", .{
        first.buffered(),
        second.buffered(),
    });
    return same;
}

fn switch_and_back(story: *Story) !void {
    assert(story.callback_depth == 0);
    const name = flows_module.current_name(&story.state);
    var buffer: [state_module.flow_name_bytes_max]u8 = undefined;
    @memcpy(buffer[0..name.len], name);
    story.switch_flow("simulated") catch return;
    story.switch_flow(buffer[0..name.len]) catch return;
}

fn set_some_variable(story: *Story, random: *DotnetRandom) !void {
    assert(story.state.globals.len == story.program.globals.len);
    assert(story.callback_depth == 0);
    const globals = story.program.globals;
    if (globals.len == 0) return;
    const slot: usize = @intCast(@rem(random.next(), @as(i32, @intCast(globals.len))));
    const value = story.state.globals[slot];
    const name = story.program.strings.get(globals[slot].name);
    const changed: @import("../runtime/value.zig").Value = switch (value) {
        .integer => |number| .{ .integer = number +% 1 },
        .bool => |flag| .{ .bool = !flag },
        .float => |number| .{ .float = number + 0.5 },
        .null, .variable_pointer, .tag => return,
        else => value,
    };
    try story.set_variable(name, changed);
}

/// evaluate_function on a top-level knot, function or not: the state must stay sound.
fn evaluate_some_knot(story: *Story, random: *DotnetRandom) void {
    assert(story.callback_depth == 0);
    const root = story.program.table().get(story.program.root_container());
    if (root.named_count == 0) return;
    const pick: u32 = @intCast(@rem(random.next(), @as(i32, @intCast(root.named_count))));
    const entry = story.program.named[root.named_first + pick];
    const name = story.program.strings.get(entry.name);
    var discarding: std.Io.Writer.Discarding = .init(&.{});
    _ = evaluate_module.evaluate_function(story, name, &.{}, &discarding.writer) catch return;
}

/// choose_path_string to a top-level knot, function or not: an error is an answer, but the
/// state must stay sound.
fn choose_some_knot(story: *Story, random: *DotnetRandom) void {
    assert(story.callback_depth == 0);
    const root = story.program.table().get(story.program.root_container());
    if (root.named_count == 0) return;
    const pick: u32 = @intCast(@rem(random.next(), @as(i32, @intCast(root.named_count))));
    const entry = story.program.named[root.named_first + pick];
    const name = story.program.strings.get(entry.name);
    story_paths.choose_path_string(story, name, true, &.{}) catch return;
}

/// Prepares a story for simulation: bindings, a quiet error handler, the compaction mode.
pub fn prepare(story: *Story, compact_always: bool) void {
    assert(story.bindings.len == story.program.externals.len);
    support.quiet(story);
    story.state.compact_always = compact_always;
}

test "the simulation keeps the state sound" {
    // A few seeds of the full action mix on every ground-truth case, with and without
    // compact-always. `zig build simulate` runs many more.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const save_buffer = try arena.alloc(u8, 2 << 20);
    for (try cases.ids(arena, io)) |id| {
        const path = try std.fmt.allocPrint(arena, "test/ground_truth/{s}.ink.json", .{id});
        const json = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 << 20));
        var program = ink_json.load(arena, json) catch continue;
        var story: Story = undefined;
        try story.init(std.testing.allocator, &program, .{});
        defer story.deinit(std.testing.allocator);
        for ([_]bool{ false, true }) |compact_always| {
            prepare(&story, compact_always);
            for ([_]i32{ 1, 2, 3 }) |seed| {
                const finding = simulate(&story, seed, save_buffer) catch |err| switch (err) {
                    error.StepLimit => Finding.ok,
                    else => return err,
                };
                std.testing.expectEqual(Finding.ok, finding) catch |err| {
                    std.debug.print("case {s}, seed {d}, compact_always {}\n", .{
                        id,
                        seed,
                        compact_always,
                    });
                    return err;
                };
            }
        }
    }
}

test "a swarm mix takes only its actions, and the full mix is the old one" {
    // A drawn mix never takes an action with weight 0; the full mix plays the same as
    // `simulate`; a mix's code round-trips through `--swarm-config`.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const save_buffer = try arena.alloc(u8, 2 << 20);
    const path = "test/ground_truth/runtime/weaves/weave_gathers.ink.json";
    const json = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 << 20));
    var program = try ink_json.load(arena, json);
    var story: Story = undefined;
    try story.init(std.testing.allocator, &program, .{});
    defer story.deinit(std.testing.allocator);
    prepare(&story, false);
    var differs: u32 = 0;
    for (1..64) |seed_index| {
        const seed: i32 = @intCast(seed_index);
        const mix = Mix.draw(seed);
        try std.testing.expectEqual(mix.encode(), (try Mix.decode(mix.encode())).encode());
        if (mix.encode() != Mix.full.encode()) differs += 1;
        var counts: std.EnumArray(Mix.Action, u32) = .initFill(0);
        _ = try simulate_mix(&story, seed, mix, save_buffer, &counts);
        for (std.enums.values(Mix.Action)) |action| {
            if (mix.weights.get(action) == 0) try std.testing.expectEqual(0, counts.get(action));
        }
        try std.testing.expectEqual(
            try simulate(&story, seed, save_buffer),
            try simulate_mix(&story, seed, .full, save_buffer, null),
        );
    }
    try std.testing.expect(differs > 32);
    try std.testing.expectError(error.InvalidMix, Mix.decode(1 << 50));
}
