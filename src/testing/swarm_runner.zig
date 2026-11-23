//! `zig build swarm` (plan §3.7): seeded swarm runs out of the fuzzer, for long runs in
//! ReleaseSafe. Each seed draws a configuration and a generated story, and the target checks
//! it; every failure prints its configuration and the command that reproduces it, and the
//! run ends with the triage (`swarm_triage.zig`).

const std = @import("std");
const assert = std.debug.assert;
const fuzz_ink = @import("fuzz_ink.zig");
const triage_module = @import("swarm_triage.zig");
const swarm_mutate = @import("swarm_mutate.zig");
const compile = @import("../compiler/compile.zig");
const messages = @import("../compiler/messages.zig");
const api = @import("../runtime/story.zig");
const fuzz_play = @import("../fuzz/play.zig");
const fuzz_host = @import("../fuzz/host.zig");
const simulation = @import("simulation.zig");
const fuzz_limits = @import("../fuzz/limits.zig");
const ink_json = @import("../core/ink_json.zig");
const program_image = @import("../core/program_image.zig");
const program_testing = @import("../core/program_testing.zig");
const limits_module = @import("../core/limits.zig");
const Limits = limits_module.Limits;
const Swarm = fuzz_ink.Swarm;
const Mix = simulation.Mix;

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
    /// Plays a story with `hub` and `typed` on as a host does: the simulator's action mix
    /// (`simulation.simulate_mix`, the mix drawn from the seed or given by `--mix`) with
    /// observers on every global, then a session of host calls (`fuzz/host.zig`); the state
    /// checks after every call. Leaves out the program checks, which play and save make.
    host,
    /// Compiles a ground-truth story with seeded mutations (`swarm_mutate`): a mutant that
    /// fails counts its first error's code; one that compiles gets the program checks and,
    /// by the seed's parity, the play target's plays or the save target's.
    mutate,
    /// Fails when glue is on and RANDOM is off: the runner's own test.
    synthetic,
    /// The host target, failing when its mix took a `set_variable`: the runner's own test of
    /// the host target's report.
    host_synthetic,

    fn hosts(target: Target) bool {
        return target == .host or target == .host_synthetic;
    }
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
    /// The host target's: the actions its mixes took, the host calls made after them, the
    /// changes the observers saw, and the actions and calls that returned an error, by name.
    actions: std.EnumArray(Mix.Action, u32) = .initFill(0),
    host_calls: u32 = 0,
    observed: u64 = 0,
    host_errors: Codes = .{},
    /// The mutate target's: the mutations its mutants had, by name.
    mutations: std.EnumArray(swarm_mutate.Mutation, u32) = .initFill(0),

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
        var mutations: u32 = 0;
        for (summary.mutations.values) |count| mutations += count;
        if (mutations > 0) {
            try writer.print("; compiled {d} of {d} mutants, mutations", .{
                summary.runs - summary.compile_failures,
                summary.runs,
            });
            const values = std.enums.values(swarm_mutate.Mutation);
            for (values, summary.mutations.values, 0..) |mutation, count, index| {
                const separator = if (index == 0) " " else ", ";
                try writer.print("{s}{t} {d}", .{ separator, mutation, count });
            }
        }
        if (summary.host_calls == 0) return;
        try writer.writeAll("; actions");
        for (std.enums.values(Mix.Action), 0..) |action, index| {
            const separator = if (index == 0) " " else ", ";
            try writer.print("{s}{t} {d}", .{ separator, action, summary.actions.get(action) });
        }
        try writer.print("; host calls {d}, observed {d}, host errors {d}", .{
            summary.host_calls,
            summary.observed,
            summary.host_errors.total(),
        });
        try summary.host_errors.write_top(writer, 4);
    }
};

/// Compile failures by diagnostic code: the codes are the compiler's static names, so the
/// table keeps the slices; codes past its capacity count as `other`.
pub const Codes = struct {
    names: [capacity][]const u8 = undefined,
    counts: [capacity]u32 = undefined,
    len: u8 = 0,
    other: u32 = 0,

    const capacity = 128;

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

    fn total(codes: *const Codes) u32 {
        var sum = codes.other;
        for (codes.counts[0..codes.len]) |count| sum += count;
        return sum;
    }

    pub fn count_of(codes: *const Codes, name: []const u8) u32 {
        for (codes.names[0..codes.len], codes.counts[0..codes.len]) |known, count| {
            if (std.mem.eql(u8, known, name)) return count;
        }
        return 0;
    }

    /// ` (code n, code n, ...)` for the `top` most frequent codes, or nothing.
    pub fn write_top(codes: *const Codes, writer: *std.Io.Writer, top: u8) !void {
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

/// The seed `run` is on, for a panic handler to print (a crash loses the buffered output).
pub const Running = struct { target: Target, seed: u64 };
pub var running: ?Running = null;

/// What a run gets besides its target and seeds.
pub const Inputs = struct {
    /// Replaces the host targets' drawn mixes.
    mix: ?Mix = null,
    /// The mutate target's stories.
    corpus: ?*const swarm_mutate.Corpus = null,
};

/// Runs seeds from `seed_first` on `target` within `budget`, writing failures and the triage.
pub fn run(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    target: Target,
    seed_first: u64,
    budget: Budget,
    inputs: Inputs,
) !Summary {
    assert(budget.seeds > 0);
    assert((budget.deadline == null) == (budget.io == null));
    assert((target == .mutate) == (inputs.corpus != null));
    var summary: Summary = .{};
    var triage: triage_module.Triage = .{};
    const save_buffer = try gpa.alloc(u8, if (target.hosts()) host_save_bytes else 0);
    defer gpa.free(save_buffer);
    const mutant_buffers = try gpa.alloc(swarm_mutate.Buffers, @intFromBool(target == .mutate));
    defer gpa.free(mutant_buffers);
    for (0..budget.seeds) |offset| {
        if (offset > 0 and budget.exhausted()) break;
        const seed = seed_first + offset;
        running = .{ .target = target, .seed = seed };
        defer running = null;
        var buffer: [fuzz_ink.source_bytes_max]u8 = undefined;
        var mutant: ?swarm_mutate.Mutant = null;
        const case: fuzz_ink.Generator.Case = if (target.hosts())
            generate_hosted(seed, &buffer)
        else if (inputs.corpus) |corpus| mutated: {
            mutant = swarm_mutate.mutate(corpus, seed, &mutant_buffers[0]);
            for (mutant.?.mutations()) |mutation| summary.mutations.getPtr(mutation).* += 1;
            break :mutated .{ .source = mutant.?.source, .swarm = .none, .used = .none };
        } else fuzz_ink.generate_case_seeded(seed, &buffer, .{});
        summary.runs += 1;
        const host: Host = .{ .plan = .draw(seed, inputs.mix), .save_buffer = save_buffer };
        const failure = try check_case(gpa, target, seed, case, host, &summary);
        // A mutant has no swarm configuration to triage.
        if (mutant == null) triage.add(case.swarm, failure != null);
        const reason = failure orelse continue;
        summary.failures += 1;
        try writer.print("failure ({s}): seed {d}, ", .{ reason, seed });
        if (mutant) |m| {
            try writer.print("mutant: {f}\n", .{m});
        } else {
            try writer.print("swarm: {f}\n", .{case.swarm});
        }
        try writer.print("reproduce with: zig build swarm -Doptimize=ReleaseSafe -- " ++
            "--target {t} --seed {d} --seeds 1", .{ target, seed });
        if (target.hosts()) try writer.print(" --mix {x}", .{host.plan.mix.encode()});
        try writer.writeByte('\n');
        // Reproducing one seed shows the mutant.
        if (mutant != null and budget.seeds == 1) {
            try writer.print("mutant source:\n{s}\n", .{case.source});
        }
    }
    try writer.print("swarm {t}: {f}\n", .{ target, summary });
    if (target == .mutate) {
        try writer.writeAll("swarm mutate: compile failures by code");
        try summary.codes.write_top(writer, Codes.capacity);
        try writer.writeByte('\n');
    } else try triage.report(writer);
    return summary;
}

/// Null when the seed's case passes; otherwise what failed.
fn check_case(
    gpa: std.mem.Allocator,
    target: Target,
    seed: u64,
    case: fuzz_ink.Generator.Case,
    host: Host,
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
    if (target.hosts()) {
        return play_host(gpa, &program, seed, host, target == .host_synthetic, summary);
    }
    if (try check_program(gpa, case.source, &program)) |failure| return failure;
    switch (target) {
        .compile => {},
        .play, .save => return play(gpa, &program, seed, target == .save, summary),
        // Half the mutants play as the play target does, half as the save target does.
        .mutate => return play(gpa, &program, seed, seed % 2 == 1, summary),
        .synthetic, .host, .host_synthetic => unreachable,
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

/// The seed's case for the host targets: its drawn swarm with `hub` and `typed` on, so that
/// the host's actions act on a story that plays through choices, and without `drop` and
/// `collision`, which fail the compile (the play targets cover them).
fn generate_hosted(seed: u64, buffer: []u8) fuzz_ink.Generator.Case {
    var prng: std.Random.DefaultPrng = .init(seed);
    const choices: fuzz_ink.Choices = .{ .random = prng.random() };
    const options: fuzz_ink.Options = .{};
    var swarm = options.swarm orelse Swarm.draw(choices);
    swarm.play.insert(.hub);
    swarm.play.insert(.typed);
    swarm.resolution.remove(.drop);
    swarm.resolution.remove(.collision);
    swarm.normalize();
    return fuzz_ink.Generator.generate_case(choices, buffer, .{ .swarm = swarm });
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

/// The bytes the simulator's save and load holds its two saves in; a larger save skips it.
const host_save_bytes = 1 << 20;

/// What a host target's seed gets besides its story.
const Host = struct {
    plan: HostPlan,
    /// `host_save_bytes` for the host targets, else empty.
    save_buffer: []u8,
};

/// How the host target sets up and plays a seed's story: drawn from the seed, apart from
/// the generator's draws.
const HostPlan = struct {
    setup: fuzz_play.Setup,
    mix: Mix,
    /// The calls of the session after the mix.
    calls: fuzz_host.CallSet,

    /// Mixed into the seed, so the plan doesn't repeat the generator's or `Plan`'s draws.
    const salt = 0x4057_4057;

    /// The seed's plan, with `mix` in place of the drawn one when given.
    fn draw(seed: u64, mix: ?Mix) HostPlan {
        var prng: std.Random.DefaultPrng = .init(seed ^ salt);
        const choices: fuzz_ink.Choices = .{ .random = prng.random() };
        var setup: fuzz_play.Setup = .pick(choices);
        // A story without `e0` stops at its first line; the play target covers that.
        if (!setup.fallbacks) setup.bind_external = true;
        const calls = fuzz_host.draw_calls(choices);
        // Drawn last, so the draws before keep their seeds' values.
        setup.evaluate_in_external = choices.choose(bool);
        return .{
            .setup = setup,
            .mix = mix orelse .draw(simulation_seed(seed)),
            .calls = calls,
        };
    }
};

/// The simulator's seed (`new Random(seed)`) for a swarm seed.
fn simulation_seed(seed: u64) i32 {
    return @bitCast(@as(u32, @truncate(seed)));
}

/// What a host target's story reported: errors and the changes its observers saw.
const HostTrace = struct {
    errored: bool = false,
    observed: u64 = 0,

    fn note(context: ?*anyopaque, message: []const u8, severity: api.Severity) void {
        const trace: *HostTrace = @ptrCast(@alignCast(context.?));
        assert(message.len > 0);
        if (severity == .@"error") trace.errored = true;
    }

    fn observe(context: ?*anyopaque, name: []const u8, value: api.Value) void {
        const trace: *HostTrace = @ptrCast(@alignCast(context.?));
        assert(name.len > 0);
        _ = value;
        trace.observed += 1;
    }
};

/// Plays `program`'s story as the seed's host plan says: an observer on every global, the
/// simulator's mix (seeded choices, lines, and one action of the mix per turn), then a
/// session of host calls. Null when the state checked after every call and the simulator's
/// save and load saved the same; otherwise what failed. With `synthetic`, a mix that took a
/// `set_variable` fails.
fn play_host(
    gpa: std.mem.Allocator,
    program: *const Program,
    seed: u64,
    host: Host,
    synthetic: bool,
    summary: *Summary,
) !?[]const u8 {
    assert(host.save_buffer.len == host_save_bytes);
    const plan = host.plan;
    var story: api.Story = undefined;
    try fuzz_play.init_story(&story, gpa, program, plan.setup);
    defer story.deinit(gpa);
    var trace: HostTrace = .{};
    story.on_error = HostTrace.note;
    story.on_error_context = &trace;
    for (0..story.global_variable_count()) |position| {
        const name = story.global_variable_name(@intCast(position)).?;
        story.observe_variable(name, &trace, HostTrace.observe) catch |err| switch (err) {
            // Past `observers_max`, the globals left go unobserved.
            error.ObserverLimit => break,
            error.VariableNotDeclared => unreachable,
        };
    }
    story.state.compact_always = plan.mix.compact_always;

    var tally: simulation.Tally = .{};
    const mixed = simulation.simulate_mix(
        &story,
        simulation_seed(seed),
        plan.mix,
        host.save_buffer,
        &tally,
    ) catch |err| mixed: {
        // An error is an answer (a limit, a failed external, a story failed closed).
        if (err == error.OutOfMemory) return err;
        summary.host_errors.add(@errorName(err), 1);
        break :mixed .ok;
    };
    for (&summary.actions.values, tally.actions.values) |*total, count| total.* += count;
    summary.lines += tally.lines;
    summary.choices += tally.choices;
    switch (mixed) {
        .ok => {},
        .check_failed => return "State.check in the mix",
        .round_trip_differs => return "the mix's save and load saved another save",
    }
    if (synthetic and tally.actions.get(.set_variable) > 0) return "synthetic set_variable";
    if (story.state.check() != .ok) return "State.check after the mix";

    var prng: std.Random.DefaultPrng = .init(seed ^ HostPlan.salt ^ 1);
    const choices: fuzz_ink.Choices = .{ .random = prng.random() };
    var kept: ?api.Value = null;
    var count: u32 = 0;
    while (count < fuzz_host.calls_max and choices.more(7, 1)) : (count += 1) {
        // After an error in the middle of a step the story fails closed until reset_state
        // or load_json, which the session may call.
        _ = fuzz_host.call(gpa, &story, choices, &kept, plan.calls) catch |err| {
            if (err == error.OutOfMemory) return err;
            summary.host_errors.add(@errorName(err), 1);
        };
        if (story.state.check() != .ok) return "State.check after a host call";
    }
    summary.host_calls += count;
    summary.observed += trace.observed;
    summary.runtime_errors += @intFromBool(trace.errored);
    return null;
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
    // Two codes and `capacity - 1` others: the last one counts as other.
    var storage: [Codes.capacity - 1][4]u8 = undefined;
    for (&storage, 0..) |*name, index| codes.add(try std.fmt.bufPrint(name, "c{d}", .{index}), 1);
    try std.testing.expectEqual(@as(u32, 1), codes.other);
}

test "a passed deadline stops the run after its first seed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const budget: Budget = .{ .seeds = 1000, .deadline = .now(io, .awake), .io = io };
    const summary = try run(gpa, &out.writer, .synthetic, 1, budget, .{});
    try std.testing.expectEqual(@as(u32, 1), summary.runs);
}

test "the host target passes a few seeds, and reports a failing action with its mix" {
    // P18.5: a few seeds of the host target make their mixes' actions and host calls and
    // pass; the synthetic host target fails a seed whose mix took a set_variable, and its
    // reproduce line names the seed and the mix, which `--mix` replays.
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const passed = try run(gpa, &out.writer, .host, 1, .{ .seeds = 6 }, .{});
    try std.testing.expectEqual(@as(u32, 0), passed.failures);
    try std.testing.expect(passed.host_calls > 0);
    var actions: u32 = 0;
    for (passed.actions.values) |count| actions += count;
    try std.testing.expect(actions > 0);

    out.clearRetainingCapacity();
    const failed = try run(gpa, &out.writer, .host_synthetic, 1, .{ .seeds = 6 }, .{});
    try std.testing.expect(failed.failures > 0 and failed.failures < failed.runs);
    const text = out.written();
    const prefix = "failure (synthetic set_variable): seed ";
    const seed_text = text[std.mem.indexOf(u8, text, prefix).? + prefix.len ..];
    const seed_end = std.mem.indexOfScalar(u8, seed_text, ',').?;
    const seed = try std.fmt.parseInt(u64, seed_text[0..seed_end], 10);
    const mix = HostPlan.draw(seed, null).mix;
    var expected: [160]u8 = undefined;
    const line = try std.fmt.bufPrint(&expected, "reproduce with: zig build swarm " ++
        "-Doptimize=ReleaseSafe -- --target host_synthetic --seed {d} --seeds 1 --mix {x}\n", .{
        seed, mix.encode(),
    });
    try std.testing.expect(std.mem.indexOf(u8, text, line) != null);

    // The printed mix replays the failure; the same seed without set_variable passes.
    out.clearRetainingCapacity();
    const budget: Budget = .{ .seeds = 1 };
    const decoded = try Mix.decode(mix.encode());
    const replayed = try run(gpa, &out.writer, .host_synthetic, seed, budget, .{ .mix = decoded });
    try std.testing.expectEqual(@as(u32, 1), replayed.failures);
    var without = mix;
    without.weights.set(.set_variable, 0);
    const passes = try run(gpa, &out.writer, .host_synthetic, seed, budget, .{ .mix = without });
    try std.testing.expectEqual(@as(u32, 0), passes.failures);
}

test "the mutate target passes a few seeds of a ground-truth story and counts its mutants" {
    // P19.3: 24 mutants of one story (read from disk) pass the program checks and the plays;
    // some compile and play, some fail with a counted code, and each mutation is counted.
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const id = "runtime/diverts/tunnel_vs_thread_behaviour";
    const arena = arena_state.allocator();
    const corpus = try swarm_mutate.Corpus.load_ids(arena, std.testing.io, &.{id});
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const summary = try run(gpa, &out.writer, .mutate, 1, .{ .seeds = 24 }, .{ .corpus = &corpus });
    try std.testing.expectEqual(@as(u32, 0), summary.failures);
    try std.testing.expect(summary.compile_failures > 0);
    try std.testing.expect(summary.compile_failures < summary.runs);
    try std.testing.expectEqual(summary.compile_failures, summary.codes.total());
    try std.testing.expect(summary.lines > 0);
    var mutations: u32 = 0;
    for (summary.mutations.values) |count| mutations += count;
    try std.testing.expect(mutations >= summary.runs);
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "mutants, mutations delete_line") != null);
    const codes_line = "swarm mutate: compile failures by code (";
    try std.testing.expect(std.mem.indexOf(u8, text, codes_line) != null);
}
