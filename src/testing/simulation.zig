//! The deterministic story simulator (plan P0.9), run with `zig build simulate`. For each seed
//! it plays every ground-truth case with seeded random choices (`play_seeded <seed>`), each
//! run in its own process, and reports runs that crash. A run depends only on its engine,
//! case and seed, so every report carries the command that reproduces it.
//!
//! In P0 it drives the old runtime with random choices only. P5.12 enables the full action mix
//! (save/load points, flow switches, `evaluate_function`, `set_variable`, compact-always) and
//! `State.verify()` after every `cont()` on the new engine.

const std = @import("std");
const assert = std.debug.assert;
const build_options = @import("build_options");

pub const Outcome = enum { ok, crash };

pub const Run = struct {
    outcome: Outcome,
    transcript: []const u8,
};

/// Plays case `id` on `engine` with choices from `new Random(seed)`, in a child process.
pub fn run_seed(
    arena: std.mem.Allocator,
    io: std.Io,
    engine: []const u8,
    id: []const u8,
    seed: i32,
) !Run {
    assert(id.len > 0);
    assert(engine.len > 0);
    const actions = try std.fmt.allocPrint(arena, "play_seeded {d}", .{seed});
    const result = try std.process.run(arena, io, .{
        .argv = &.{ build_options.replay_case_path, engine, id, "--actions", actions },
        .stdout_limit = .limited(16 * 1024 * 1024),
        .stderr_limit = .limited(16 * 1024 * 1024),
    });
    const crashed = switch (result.term) {
        .exited => |code| code != 0,
        else => true,
    };
    const run: Run = .{ .outcome = if (crashed) .crash else .ok, .transcript = result.stdout };
    assert(run.outcome == .crash or run.transcript.len > 0);
    return run;
}

test "a simulation run is reproducible by seed" {
    // Goal: P0.9; the same engine, case and seed give the same run, and other seeds explore
    // other paths. Method: run a branching weave twice with one seed, then with others.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const id = "runtime/weaves/weave_gathers";
    const first = try run_seed(arena, io, "old", id, 7);
    const again = try run_seed(arena, io, "old", id, 7);
    try std.testing.expectEqual(Outcome.ok, first.outcome);
    try std.testing.expectEqualStrings(first.transcript, again.transcript);
    var differs = false;
    for ([_]i32{ 1, 2, 3, 4, 5, 6 }) |seed| {
        const other = try run_seed(arena, io, "old", id, seed);
        differs = differs or !std.mem.eql(u8, other.transcript, first.transcript);
    }
    try std.testing.expect(differs);
}

const ink_json = @import("../core/ink_json.zig");
const Program = @import("../core/program.zig").Program;
const DotnetRandom = @import("../core/dotnet_random.zig").DotnetRandom;
const story_module = @import("../vm/story.zig");
const state_module = @import("../vm/state.zig");
const flows_module = @import("../vm/flows.zig");
const save_module = @import("../vm/save.zig");
const load_module = @import("../vm/load.zig");
const evaluate_module = @import("../vm/evaluate.zig");
const Story = story_module.Story;

/// What the new engine's simulation found in one run.
pub const Finding = enum { ok, check_failed, round_trip_differs };

fn ignore_message(
    context: ?*anyopaque,
    message: []const u8,
    severity: state_module.Diagnostic.Severity,
) void {
    assert(context == null);
    assert(message.len > 0 or severity == .warning);
}

fn noop_external(
    context: ?*anyopaque,
    story: *Story,
    arguments: []const story_module.HostValue,
) anyerror!story_module.HostValue {
    assert(context == null);
    assert(arguments.len <= story_module.external_arguments_max and story.callback_depth > 0);
    return .{ .integer = 1 };
}

/// Plays `story` with the full action mix (P5.12) driven by `new Random(seed)`: seeded
/// choices, save and load points, flow switches, evaluate_function on the story's knots,
/// set_variable, and State.check after every cont. `save_buffer` holds the saves.
pub fn simulate_new(story: *Story, seed: i32, save_buffer: []u8) !Finding {
    assert(story.state.memory.len > 0);
    assert(save_buffer.len > 0);
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
        if (roll < 15 and try round_trip(story, save_buffer) == false) return .round_trip_differs;
        if (roll >= 15 and roll < 25) try switch_and_back(story);
        if (roll >= 25 and roll < 35) try set_some_variable(story, &random);
        if (roll >= 35 and roll < 40) evaluate_some_knot(story, &random);
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
    assert(!@import("../vm/lookahead.zig").active(&story.state));
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
    assert(story.state.flows.len > 0);
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
    const changed: @import("../vm/value.zig").Value = switch (value) {
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
    assert(story.program.containers.len > 0);
    assert(story.callback_depth == 0);
    const root = story.program.table().get(story.program.root_container());
    if (root.named_count == 0) return;
    const pick: u32 = @intCast(@rem(random.next(), @as(i32, @intCast(root.named_count))));
    const entry = story.program.named[root.named_first + pick];
    const name = story.program.strings.get(entry.name);
    var discarding: std.Io.Writer.Discarding = .init(&.{});
    _ = evaluate_module.evaluate_function(story, name, &.{}, &discarding.writer) catch return;
}

/// Prepares a story for simulation: bindings, a quiet error handler, the compaction mode.
pub fn prepare_new(story: *Story, compact_always: bool) void {
    assert(story.bindings.len == story.program.externals.len);
    assert(story.state.memory.len > 0);
    for (story.program.externals) |external| {
        const name = story.program.strings.get(external.name);
        story.bind_external_function(name, noop_external, null, true) catch {};
    }
    story.on_error = ignore_message;
    story.state.compact_always = compact_always;
}

test "the new engine's simulation keeps the state sound" {
    // Goal: P5.12; a few seeds of the full action mix on every ground-truth case, with and
    // without compact-always. `zig build simulate -- --engine new` runs many more.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const save_buffer = try arena.alloc(u8, 2 << 20);
    const ground_truth = @import("ground_truth_test.zig");
    for (try ground_truth.collect_cases(arena, io)) |id| {
        const path = try std.fmt.allocPrint(arena, "test/ground_truth/{s}.ink.json", .{id});
        const json = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 << 20));
        var program = ink_json.load(arena, json) catch continue;
        var story: Story = undefined;
        try story.init(std.testing.allocator, &program, .{});
        defer story.deinit(std.testing.allocator);
        for ([_]bool{ false, true }) |compact_always| {
            prepare_new(&story, compact_always);
            for ([_]i32{ 1, 2, 3 }) |seed| {
                const finding = simulate_new(&story, seed, save_buffer) catch |err| switch (err) {
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
