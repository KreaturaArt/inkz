//! `zig build swarm` (plan §3.7): seeded swarm runs out of the fuzzer, for long runs in
//! ReleaseSafe. Each seed draws a configuration and a generated story, and the target checks
//! it; every failure prints its configuration and the command that reproduces it, and the
//! run ends with the triage (`swarm_triage.zig`).

const std = @import("std");
const assert = std.debug.assert;
const fuzz_ink = @import("fuzz_ink.zig");
const triage_module = @import("swarm_triage.zig");
const compile = @import("../compiler/compile.zig");
const messages = @import("../compiler/messages.zig");
const api = @import("../runtime/story.zig");
const fuzz_play = @import("../fuzz/play.zig");
const fuzz_limits = @import("../fuzz/limits.zig");
const ink_json = @import("../core/ink_json.zig");
const program_image = @import("../core/program_image.zig");
const program_testing = @import("../core/program_testing.zig");
const limits_module = @import("../core/limits.zig");
const Limits = limits_module.Limits;
const Swarm = fuzz_ink.Swarm;

pub const Target = enum {
    /// Compiles; the program must pass `check_program`: the same program compiled twice and
    /// after JSON and image round trips.
    compile,
    /// Compiles (`check_program`, as the compile target) and plays with seeded choices; the
    /// state checks after every call. Most seeds play again under other limits (`Plan`): the
    /// same calls, or a limit stops it.
    play,
    /// Plays to a drawn call, saves, loads the save into a fresh story (which saves the
    /// same), and plays both on: the same calls, and the same save at the end.
    save,
    /// Fails when glue is on and RANDOM is off: the runner's own test.
    synthetic,
};

/// What the runs reached, besides their failures: how many stories compiled, how far the
/// compiled ones played, and why the others didn't. Counting allocates nothing.
pub const Summary = struct {
    runs: u32 = 0,
    failures: u32 = 0,
    /// Sources that didn't compile, counted under their first error's code.
    compile_failures: u32 = 0,
    codes: Codes = .{},
    /// Played stories that reported an error (`on_error`) or stopped at one (`cont`,
    /// `choose_choice_index`).
    runtime_errors: u32 = 0,
    /// Played stories that stopped at their first line because `e0` was neither bound nor
    /// allowed its fallback (or has none).
    unbound_externals: u32 = 0,
    /// Second plays of a seed under other limits (`Plan.limits_kind`, `compact_always`), and
    /// those of them a limit stopped where the roomy play went on (or that couldn't start);
    /// for the save target, saves too large for the loader's scratch.
    limited_runs: u32 = 0,
    limit_errors: u32 = 0,
    /// Saves (the save target's) loaded in the middle of a play and played on to its end.
    resumed_saves: u32 = 0,
    lines: u64 = 0,
    choices: u64 = 0,
    /// Played stories still going after `play_steps_max` calls.
    step_cap: u32 = 0,
    /// Played stories that ended before it without an error: at END or DONE, or with
    /// neither content nor choices left.
    ended: u32 = 0,

    pub fn format(summary: Summary, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{d} runs, {d} failures; compile failures {d}", .{
            summary.runs,
            summary.failures,
            summary.compile_failures,
        });
        try summary.codes.write_top(writer, 4);
        try writer.print("; runtime errors {d} (unbound externals {d}), limited runs {d} " ++
            "(limit errors {d}), resumed saves {d}, lines {d}, choices {d}, step cap {d}, " ++
            "ended {d}", .{
            summary.runtime_errors,
            summary.unbound_externals,
            summary.limited_runs,
            summary.limit_errors,
            summary.resumed_saves,
            summary.lines,
            summary.choices,
            summary.step_cap,
            summary.ended,
        });
    }
};

/// Compile failures by diagnostic code: the codes are the compiler's static names, so the
/// table keeps the slices; codes past its capacity count as `other`.
pub const Codes = struct {
    names: [capacity][]const u8 = undefined,
    counts: [capacity]u32 = undefined,
    len: u8 = 0,
    other: u32 = 0,

    const capacity = 16;

    fn add(codes: *Codes, name: []const u8, count: u32) void {
        assert(codes.len <= capacity);
        for (codes.names[0..codes.len], codes.counts[0..codes.len]) |known, *known_count| {
            if (std.mem.eql(u8, known, name)) {
                known_count.* += count;
                return;
            }
        }
        if (codes.len == capacity) {
            codes.other += count;
            return;
        }
        codes.names[codes.len] = name;
        codes.counts[codes.len] = count;
        codes.len += 1;
    }

    pub fn count_of(codes: *const Codes, name: []const u8) u32 {
        for (codes.names[0..codes.len], codes.counts[0..codes.len]) |known, count| {
            if (std.mem.eql(u8, known, name)) return count;
        }
        return 0;
    }

    /// ` (code n, code n, ...)` for the `top` most frequent codes, or nothing.
    fn write_top(codes: *const Codes, writer: *std.Io.Writer, top: u8) !void {
        if (codes.len == 0) return;
        var order: [capacity]u8 = undefined;
        for (order[0..codes.len], 0..) |*slot, index| slot.* = @intCast(index);
        const by_count = struct {
            fn more(counts: *const [capacity]u32, a: u8, b: u8) bool {
                return counts[a] > counts[b];
            }
        }.more;
        std.sort.insertion(u8, order[0..codes.len], &codes.counts, by_count);
        try writer.writeAll(" (");
        for (order[0..@min(top, codes.len)], 0..) |index, position| {
            if (position > 0) try writer.writeAll(", ");
            try writer.print("{s} {d}", .{ codes.names[index], codes.counts[index] });
        }
        if (codes.len > top or codes.other > 0) try writer.writeAll(", ...");
        try writer.writeByte(')');
    }
};

/// How long a run goes: `seeds` seeds, or fewer when `deadline` passes first.
pub const Budget = struct {
    seeds: u32,
    deadline: ?std.Io.Timestamp = null,
    io: ?std.Io = null,

    fn exhausted(budget: Budget) bool {
        const deadline = budget.deadline orelse return false;
        return std.Io.Timestamp.now(budget.io.?, .awake).nanoseconds >= deadline.nanoseconds;
    }
};

/// Runs seeds from `seed_first` on `target` within `budget`, writing failures and the triage.
pub fn run(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    target: Target,
    seed_first: u64,
    budget: Budget,
) !Summary {
    assert(budget.seeds > 0);
    assert((budget.deadline == null) == (budget.io == null));
    var summary: Summary = .{};
    var triage: triage_module.Triage = .{};
    for (0..budget.seeds) |offset| {
        if (offset > 0 and budget.exhausted()) break;
        const seed = seed_first + offset;
        var buffer: [fuzz_ink.source_bytes_max]u8 = undefined;
        const case = fuzz_ink.generate_case_seeded(seed, &buffer, .{});
        summary.runs += 1;
        const failure = try check_case(gpa, target, seed, case, &summary);
        triage.add(case.swarm, failure != null);
        const reason = failure orelse continue;
        summary.failures += 1;
        try writer.print("failure ({s}): seed {d}, swarm: {f}\nreproduce with: zig build swarm " ++
            "-Doptimize=ReleaseSafe -- --target {t} --seed {d} --seeds 1\n", .{
            reason, seed, case.swarm, target, seed,
        });
    }
    try writer.print("swarm {t}: {f}\n", .{ target, summary });
    try triage.report(writer);
    return summary;
}

/// Null when the seed's case passes; otherwise what failed.
fn check_case(
    gpa: std.mem.Allocator,
    target: Target,
    seed: u64,
    case: fuzz_ink.Generator.Case,
    summary: *Summary,
) !?[]const u8 {
    if (target == .synthetic) {
        const fails = case.swarm.lines.contains(.glue) and !case.swarm.terms.contains(.random);
        return if (fails) "synthetic" else null;
    }
    var first_error: ?[]const u8 = null;
    const sink: messages.Sink = .{ .context = &first_error, .function = keep_first_error };
    var program = compile.compile_source_with(gpa, case.source, .{
        .diagnostics = sink,
    }) catch |err| switch (err) {
        error.CompileFailed => {
            summary.compile_failures += 1;
            summary.codes.add(first_error orelse "none", 1);
            return null;
        },
        else => return err,
    };
    defer program.deinit(gpa);
    if (try check_program(gpa, case.source, &program)) |failure| return failure;
    switch (target) {
        .compile => {},
        .play, .save => return play(gpa, &program, seed, target == .save, summary),
        .synthetic => unreachable,
    }
    return null;
}

/// Null when `program` (compiled from `source`) passes `Program.check` and is the same
/// program, array by array, compiled again, serialized to JSON and loaded, and written to
/// an image and loaded; otherwise what failed.
fn check_program(gpa: std.mem.Allocator, source: []const u8, program: *const Program) !?[]const u8 {
    if (program.check() != .ok) return "Program.check";
    var again = try compile.compile_source(gpa, source);
    defer again.deinit(gpa);
    if (program_testing.first_difference(program, &again) != null) return "not deterministic";

    var json: std.Io.Writer.Allocating = .init(gpa);
    defer json.deinit();
    try ink_json.serialize(gpa, program, &json.writer);
    var from_json = ink_json.load(gpa, json.written()) catch |err| {
        if (err == error.OutOfMemory) return err;
        return "load of its JSON";
    };
    defer from_json.deinit(gpa);
    if (program_testing.first_difference(program, &from_json) != null) return "JSON round trip";

    var image: std.Io.Writer.Allocating = .init(gpa);
    defer image.deinit();
    try program_image.write(program, &image.writer);
    var from_image = program_image.load(gpa, image.written()) catch |err| {
        if (err == error.OutOfMemory) return err;
        return "load of its image";
    };
    defer from_image.deinit(gpa);
    if (program_testing.first_difference(program, &from_image) != null) return "image round trip";
    return null;
}

fn keep_first_error(context: ?*anyopaque, diagnostic: messages.Diagnostic) void {
    const first: *?[]const u8 = @ptrCast(@alignCast(context.?));
    if (diagnostic.severity == .@"error" and first.* == null) first.* = diagnostic.code;
}

const Program = @import("../core/program.zig").Program;

/// The calls (`cont` or a choice) a played story gets.
const play_steps_max = 64;

/// What a play showed, call by call: each line, each choice count and pick, and each error
/// or warning reported, hashed, so two plays compare without keeping their text.
const Trace = struct {
    hasher: std.hash.Wyhash = .init(0),
    /// The hash after each call that returned.
    hashes: [play_steps_max]u64 = undefined,
    count: u32 = 0,
    lines: u32 = 0,
    choices: u32 = 0,
    /// Whether the story reported an error (`on_error`).
    errored: bool = false,
    end: End = .running,
    /// The error the last call returned, with `end == .failed`.
    failure: ?anyerror = null,

    const End = enum { running, ended, step_cap, failed };

    fn note(context: ?*anyopaque, message: []const u8, severity: api.Severity) void {
        const trace: *Trace = @ptrCast(@alignCast(context.?));
        trace.hasher.update(&.{@backingInt(severity)});
        trace.hasher.update(message);
        if (severity == .@"error") trace.errored = true;
    }

    fn stop(trace: *Trace, err: anyerror) ?[]const u8 {
        trace.end = .failed;
        trace.failure = err;
        return null;
    }

    fn failed_with(trace: *const Trace, err: anyerror) bool {
        const failure = trace.failure orelse return false;
        return failure == err;
    }

    /// Whether the play stopped at a limit (an error named `...Limit`).
    fn limited(trace: *const Trace) bool {
        const failure = trace.failure orelse return false;
        return std.mem.endsWith(u8, @errorName(failure), "Limit");
    }

    /// Null when `varied` is `roomy` played again; or, when `limits_may` and a limit
    /// stopped either, when they made the same calls until the first stopped, at a limit.
    /// (A roomy play can stop at a default limit, and a fitted one, sized by the peak that
    /// stopped it, then goes further.)
    fn compare(roomy: *const Trace, varied: *const Trace, limits_may: bool) ?[]const u8 {
        assert(roomy.end != .running and varied.end != .running);
        const changed = "limits changed the play";
        const count = @min(roomy.count, varied.count);
        if (!std.mem.eql(u64, roomy.hashes[0..count], varied.hashes[0..count])) return changed;
        if (limits_may and (roomy.limited() or varied.limited())) {
            if (roomy.count < varied.count and !roomy.limited()) return changed;
            if (varied.count < roomy.count and !varied.limited()) return changed;
            return null;
        }
        return if (same(roomy, varied)) null else changed;
    }

    /// Whether two plays made the same calls and stopped the same way.
    fn same(a: *const Trace, b: *const Trace) bool {
        assert(a.end != .running and b.end != .running);
        if (a.count != b.count or a.end != b.end or a.errored != b.errored) return false;
        if (!std.mem.eql(u64, a.hashes[0..a.count], b.hashes[0..b.count])) return false;
        const failure = b.failure orelse return a.failure == null;
        return a.failed_with(failure);
    }
};

/// Plays `story` with choices from `random` until `steps` calls are traced, the story ends
/// or a call fails; the state checks after every call. Null, or what failed.
fn advance(story: *api.Story, random: std.Random, trace: *Trace, steps: u32) ?[]const u8 {
    assert(trace.end == .running);
    assert(steps <= play_steps_max);
    while (trace.count < steps) {
        if (story.can_continue()) {
            const line = story.cont() catch |err| return trace.stop(err);
            trace.hasher.update("l");
            trace.hasher.update(line.get());
            trace.lines += 1;
        } else {
            const count = story.current_choices_count();
            if (count == 0) {
                trace.end = .ended;
                return null;
            }
            const index = random.uintLessThan(u32, @intCast(count));
            story.choose_choice_index(index) catch |err| return trace.stop(err);
            trace.hasher.update(std.mem.asBytes(&[2]u32{ count, index }));
            trace.choices += 1;
        }
        if (story.state.check() != .ok) return "State.check";
        trace.hashes[trace.count] = trace.hasher.final();
        trace.count += 1;
    }
    if (trace.count == play_steps_max) trace.end = .step_cap;
    return null;
}

/// Which limits a seed's second play gets, to compare with its play under roomy limits.
const LimitsKind = enum {
    /// None: the roomy play alone (unless the heap compacts always).
    default,
    /// The roomy play's peak usage (`Limits.fitted(usage, 1)`): no limit may stop it.
    fitted,
    /// Each field its default or tight (`fuzz/limits.zig`): a limit may stop it.
    tight,
};

/// How a seed's story is set up and played: drawn from the seed, apart from the
/// generator's draws.
const Plan = struct {
    setup: fuzz_play.Setup,
    limits_kind: LimitsKind,
    /// The second play's heap compacts at every reservation of room.
    compact_always: bool,
    /// The second play's limits with `limits_kind == .tight`.
    tight: Limits,
    /// The calls the save target plays before it saves.
    save_at: u32,

    /// Mixed into the seed, so the plan doesn't repeat the generator's draws.
    const salt = 0x5e7_0b5e7;

    fn draw(seed: u64) Plan {
        var prng: std.Random.DefaultPrng = .init(seed ^ salt);
        const choices: fuzz_ink.Choices = .{ .random = prng.random() };
        // `e0` bound, its fallback allowed, both or neither (as the fuzz targets do), and the
        // story's random seed.
        const setup: fuzz_play.Setup = .pick(choices);
        return .{
            .setup = setup,
            .limits_kind = choices.choose(LimitsKind),
            .compact_always = choices.choose(bool),
            .tight = fuzz_limits.draw_limits(choices),
            .save_at = @intCast(choices.below(play_steps_max)),
        };
    }
};

fn play(
    gpa: std.mem.Allocator,
    program: *const Program,
    seed: u64,
    round_trip: bool,
    summary: *Summary,
) !?[]const u8 {
    return play_planned(gpa, program, seed, .draw(seed), round_trip, summary);
}

/// Plays the seed's story as `plan` says: with `round_trip`, saving and loading on the way,
/// else again under other limits.
fn play_planned(
    gpa: std.mem.Allocator,
    program: *const Program,
    seed: u64,
    plan: Plan,
    round_trip: bool,
    summary: *Summary,
) !?[]const u8 {
    var story: api.Story = undefined;
    try fuzz_play.init_story(&story, gpa, program, plan.setup);
    defer story.deinit(gpa);
    var trace: Trace = .{};
    story.on_error = Trace.note;
    story.on_error_context = &trace;
    var prng: std.Random.DefaultPrng = .init(seed);
    if (round_trip) {
        const saved = try play_saved(gpa, program, plan, &story, &trace, &prng, summary);
        if (saved) |failure| return failure;
    }
    // The save target's play goes on alone when its save didn't load.
    if (trace.end == .running) {
        if (advance(&story, prng.random(), &trace, play_steps_max)) |failure| return failure;
    }
    count_play(&trace, summary);
    // ink's ValidateExternalBindings, at the first `cont`.
    if (trace.failed_with(error.MissingExternalBinding) and plan.setup.bind_external) {
        return "e0 bound and missing";
    }
    if (round_trip) return null;
    const fitted = limits_module.fitted(story.usage(), 1);
    return play_limited(gpa, program, seed, plan, &trace, fitted, summary);
}

fn count_play(trace: *const Trace, summary: *Summary) void {
    assert(trace.end != .running);
    summary.lines += trace.lines;
    summary.choices += trace.choices;
    summary.runtime_errors += @intFromBool(trace.errored or trace.end == .failed);
    summary.unbound_externals += @intFromBool(trace.failed_with(error.MissingExternalBinding));
    summary.step_cap += @intFromBool(trace.end == .step_cap);
    summary.ended += @intFromBool(trace.end == .ended and !trace.errored);
}

/// Plays the seed again under the plan's limits: the same play as `roomy`'s, or (tight, or
/// fitted to a roomy play that hit a limit itself) stopped at a limit after the same calls.
fn play_limited(
    gpa: std.mem.Allocator,
    program: *const Program,
    seed: u64,
    plan: Plan,
    roomy: *const Trace,
    fitted: Limits,
    summary: *Summary,
) !?[]const u8 {
    if (plan.limits_kind == .default and !plan.compact_always) return null;
    var limits: Limits = switch (plan.limits_kind) {
        .default => .{},
        .fitted => fitted,
        .tight => plan.tight,
    };
    // `fitted` sizes buffers only; the step budget is the roomy play's.
    const steps_max = fuzz_play.steps_per_continue_max;
    if (plan.limits_kind != .tight) limits.steps_per_continue_max = steps_max;
    const limits_may = plan.limits_kind == .tight or roomy.limited();
    summary.limited_runs += 1;
    var story: api.Story = undefined;
    fuzz_play.init_story_with(&story, gpa, program, plan.setup, limits) catch |err| {
        if (err == error.OutOfMemory) return err;
        if (!limits_may) return "fitted limits too small to start";
        summary.limit_errors += 1;
        return null;
    };
    defer story.deinit(gpa);
    story.state.compact_always = plan.compact_always;
    var trace: Trace = .{};
    story.on_error = Trace.note;
    story.on_error_context = &trace;
    var prng: std.Random.DefaultPrng = .init(seed);
    if (advance(&story, prng.random(), &trace, play_steps_max)) |failure| return failure;
    summary.limit_errors += @intFromBool(trace.limited() and !roomy.limited());
    return Trace.compare(roomy, &trace, limits_may);
}

/// Plays `story` to the plan's save point and saves; the save loads into a fresh story,
/// which saves the same; then both play on with the same choices: the same calls, and the
/// same saves at the end.
fn play_saved(
    gpa: std.mem.Allocator,
    program: *const Program,
    plan: Plan,
    story: *api.Story,
    trace: *Trace,
    prng: *std.Random.DefaultPrng,
    summary: *Summary,
) !?[]const u8 {
    if (advance(story, prng.random(), trace, plan.save_at)) |failure| return failure;
    // ink's save doesn't keep a choice's isInvisibleDefault (JsonSerialisation's
    // JObjectToChoice), so a loaded fallback choice is visible, in ink and here: the save
    // waits for a call after which none is pending.
    while (trace.end == .running and invisible_choices(story)) {
        if (advance(story, prng.random(), trace, trace.count + 1)) |failure| return failure;
    }
    // A story that failed in the middle of a step is half done and doesn't save.
    if (story.failed) return null;
    const save = try save_of(gpa, story);
    defer gpa.free(save);
    var loaded: api.Story = undefined;
    try fuzz_play.init_story(&loaded, gpa, program, plan.setup);
    defer loaded.deinit(gpa);
    loaded.load_json(save) catch |err| {
        // The loader's scratch (`load_bytes_max`) holds a few times a save's size, and a
        // story's state can outgrow that: a limit, as in a second play.
        if (err != error.SaveTooLarge) return "load of its own save";
        summary.limit_errors += 1;
        return null;
    };
    const save_again = try save_of(gpa, &loaded);
    defer gpa.free(save_again);
    if (!std.mem.eql(u8, save, save_again)) return "save round trip";
    if (trace.end != .running) return null;
    var loaded_trace = trace.*;
    loaded.on_error = Trace.note;
    loaded.on_error_context = &loaded_trace;
    var loaded_prng = prng.*;
    if (advance(story, prng.random(), trace, play_steps_max)) |failure| return failure;
    const loaded_random = loaded_prng.random();
    if (advance(&loaded, loaded_random, &loaded_trace, play_steps_max)) |failure| return failure;
    if (!Trace.same(trace, &loaded_trace)) return "loaded save played differently";
    summary.resumed_saves += 1;
    if (story.failed) return null;
    const end = try save_of(gpa, story);
    defer gpa.free(end);
    const loaded_end = try save_of(gpa, &loaded);
    defer gpa.free(loaded_end);
    if (!std.mem.eql(u8, end, loaded_end)) return "loaded save ended in another save";
    return null;
}

/// Whether the story holds a choice it doesn't show: a fallback (invisible default) choice.
fn invisible_choices(story: *api.Story) bool {
    return story.state.choices.records.slice().len > story.current_choices_count();
}

fn save_of(gpa: std.mem.Allocator, story: *api.Story) ![]u8 {
    var save: std.Io.Writer.Allocating = .init(gpa);
    errdefer save.deinit();
    try story.to_json(&save.writer);
    return save.toOwnedSlice();
}

/// The trace of `source` played under `limits`, with no external bound.
fn trace_source(gpa: std.mem.Allocator, source: []const u8, limits: Limits) !Trace {
    var program = try compile.compile_source(gpa, source);
    defer program.deinit(gpa);
    var story: api.Story = undefined;
    const setup: fuzz_play.Setup = .{
        .random_seed = 0,
        .fallbacks = false,
        .bind_external = false,
    };
    try fuzz_play.init_story_with(&story, gpa, &program, setup, limits);
    defer story.deinit(gpa);
    var trace: Trace = .{};
    story.on_error = Trace.note;
    story.on_error_context = &trace;
    var prng: std.Random.DefaultPrng = .init(1);
    try std.testing.expect(advance(&story, prng.random(), &trace, play_steps_max) == null);
    return trace;
}

test "the limits comparison catches a play that differs, and lets a limit stop one" {
    // P18.3, synthetic: a play compares with itself, not with a play that shows one other
    // line; a play a limit stopped compares with the roomy play up to where it stopped (if
    // limits may stop it), not when its lines before differ.
    const gpa = std.testing.allocator;
    const roomy_limits: Limits = .{ .steps_per_continue_max = 10_000 };
    const roomy = try trace_source(gpa, "A\nB\nC\n* x\n* y\n- D\n-> END\n", roomy_limits);
    try std.testing.expectEqual(Trace.End.ended, roomy.end);
    try std.testing.expectEqual(@as(u32, 1), roomy.choices);
    const same = try trace_source(gpa, "A\nB\nC\n* x\n* y\n- D\n-> END\n", roomy_limits);
    try std.testing.expect(Trace.compare(&roomy, &same, false) == null);
    const other = try trace_source(gpa, "A\nB\nC\n* x\n* y\n- E\n-> END\n", roomy_limits);
    const changed = Trace.compare(&roomy, &other, true).?;
    try std.testing.expectEqualStrings("limits changed the play", changed);

    const long: [600]u8 = @splat('x');
    var tight = roomy_limits;
    tight.output_items_max = 64;
    tight.output_bytes_max = 256;
    const long_roomy = try trace_source(gpa, "A\nB\n" ++ long ++ "\n-> END\n", roomy_limits);
    const stopped = try trace_source(gpa, "A\nB\n" ++ long ++ "\n-> END\n", tight);
    try std.testing.expect(stopped.limited());
    try std.testing.expect(stopped.count > 0 and stopped.count < long_roomy.count);
    try std.testing.expect(Trace.compare(&long_roomy, &stopped, true) == null);
    try std.testing.expect(Trace.compare(&long_roomy, &stopped, false) != null);
    const stopped_other = try trace_source(gpa, "Z\nB\n" ++ long ++ "\n-> END\n", tight);
    try std.testing.expect(stopped_other.limited());
    try std.testing.expect(Trace.compare(&long_roomy, &stopped_other, true) != null);
}

test "a story saved in the middle of its play and loaded plays on the same" {
    // P18.3: a hand-made story with a global, a shuffle, RANDOM, visit counts, a tunnel and
    // once-only and sticky choices, saved after 0 to 40 calls: the loaded save plays on to
    // the step cap with the same lines, choices and errors as the story it came from, and
    // both end in the same save.
    const gpa = std.testing.allocator;
    const source =
        \\VAR score = 0
        \\-> hub
        \\=== hub ===
        \\{~Rain|Sun|Fog} over the hills. {score}
        \\~ score += RANDOM(1, 3)
        \\* [Left] Left, {hub} times.
        \\* [Right] Right.
        \\  -> tunnel ->
        \\+ [Wait] Waiting.
        \\- -> hub
        \\=== tunnel ===
        \\Through {stopping: the dark|the light}.
        \\->->
        \\
    ;
    var program = try compile.compile_source(gpa, source);
    defer program.deinit(gpa);
    var summary: Summary = .{};
    const save_points = [_]u32{ 0, 1, 3, 10, 40 };
    for (save_points) |save_at| {
        const plan: Plan = .{
            .setup = .{ .random_seed = 7, .fallbacks = false, .bind_external = false },
            .limits_kind = .default,
            .compact_always = false,
            .tight = .{},
            .save_at = save_at,
        };
        try std.testing.expect(try play_planned(gpa, &program, 1, plan, true, &summary) == null);
    }
    try std.testing.expectEqual(@as(u32, save_points.len), summary.resumed_saves);
    try std.testing.expectEqual(@as(u32, save_points.len), summary.step_cap);
    try std.testing.expectEqual(@as(u32, 0), summary.runtime_errors);
}

test "codes keep the most frequent first, and count past their capacity as other" {
    var codes: Codes = .{};
    codes.add("b", 1);
    codes.add("a", 3);
    codes.add("b", 1);
    try std.testing.expectEqual(@as(u32, 2), codes.count_of("b"));
    var text: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&text);
    try codes.write_top(&writer, 4);
    try std.testing.expectEqualStrings(" (a 3, b 2)", writer.buffered());
    const names = [_][]const u8{ "c0", "c1", "c2", "c3", "c4", "c5", "c6", "c7", "c8", "c9" } ++
        [_][]const u8{ "d0", "d1", "d2", "d3", "d4" };
    for (names) |name| codes.add(name, 1);
    try std.testing.expectEqual(@as(u32, 1), codes.other);
}

test "a passed deadline stops the run after its first seed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const budget: Budget = .{ .seeds = 1000, .deadline = .now(io, .awake), .io = io };
    const summary = try run(gpa, &out.writer, .synthetic, 1, budget);
    try std.testing.expectEqual(@as(u32, 1), summary.runs);
}
