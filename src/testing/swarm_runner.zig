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
const limits_module = @import("../core/limits.zig");
const Limits = limits_module.Limits;
const Swarm = fuzz_ink.Swarm;

pub const Target = enum {
    /// Compiles; a compiled program passes `Program.check` and compiles the same twice.
    compile,
    /// Compiles and plays with seeded choices; the state checks after every call.
    play,
    /// Plays, saves, loads the save into a fresh story, and saves again: the same save.
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
    /// those of them a limit stopped where the roomy play went on (or that couldn't start).
    limited_runs: u32 = 0,
    limit_errors: u32 = 0,
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
            "(limit errors {d}), lines {d}, choices {d}, step cap {d}, ended {d}", .{
            summary.runtime_errors,
            summary.unbound_externals,
            summary.limited_runs,
            summary.limit_errors,
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
    if (program.check() != .ok) return "Program.check";
    switch (target) {
        .compile => {
            var again = try compile.compile_source(gpa, case.source);
            defer again.deinit(gpa);
            if (again.instructions.len != program.instructions.len) return "not deterministic";
        },
        .play, .save => return play(gpa, &program, seed, target == .save, summary),
        .synthetic => unreachable,
    }
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
        if (roomy.count != varied.count or roomy.end != varied.end) return changed;
        if (roomy.errored != varied.errored) return changed;
        if (varied.failure) |failure| {
            if (!roomy.failed_with(failure)) return changed;
        }
        return null;
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
    const plan: Plan = .draw(seed);
    var story: api.Story = undefined;
    try fuzz_play.init_story(&story, gpa, program, plan.setup);
    defer story.deinit(gpa);
    var trace: Trace = .{};
    story.on_error = Trace.note;
    story.on_error_context = &trace;
    var prng: std.Random.DefaultPrng = .init(seed);
    if (advance(&story, prng.random(), &trace, play_steps_max)) |failure| return failure;
    count_play(&trace, summary);
    // ink's ValidateExternalBindings, at the first `cont`.
    if (trace.failed_with(error.MissingExternalBinding) and plan.setup.bind_external) {
        return "e0 bound and missing";
    }
    if (round_trip) return round_trip_end(gpa, program, &story, plan.setup);
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

/// The save at the end of a play loads into a fresh story, which saves the same.
fn round_trip_end(
    gpa: std.mem.Allocator,
    program: *const Program,
    story: *api.Story,
    setup: fuzz_play.Setup,
) !?[]const u8 {
    if (story.failed) return null;
    var first: std.Io.Writer.Allocating = .init(gpa);
    defer first.deinit();
    try story.to_json(&first.writer);
    var loaded: api.Story = undefined;
    try fuzz_play.init_story(&loaded, gpa, program, setup);
    defer loaded.deinit(gpa);
    loaded.load_json(first.written()) catch return "load of its own save";
    var second: std.Io.Writer.Allocating = .init(gpa);
    defer second.deinit();
    try loaded.to_json(&second.writer);
    if (!std.mem.eql(u8, first.written(), second.written())) return "save round trip";
    return null;
}

test "a failing swarm run prints the command that reproduces it, and the triage" {
    // The synthetic target fails on glue without RANDOM: each failure line carries its
    // configuration and the `zig build swarm` command for its seed, and the triage names
    // glue as the trigger (P16.6).
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const summary = try run(gpa, &out.writer, .synthetic, 100, .{ .seeds = 200 });
    try std.testing.expect(summary.failures > 0);
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "reproduce with: zig build swarm " ++
        "-Doptimize=ReleaseSafe -- --target synthetic --seed ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "trigger: lines.glue") != null);
    // The printed seed reproduces the failure alone.
    const at = std.mem.indexOf(u8, text, "--seed ").? + "--seed ".len;
    const end = std.mem.indexOfScalarPos(u8, text, at, ' ').?;
    const seed = try std.fmt.parseInt(u64, text[at..end], 10);
    var again: std.Io.Writer.Allocating = .init(gpa);
    defer again.deinit();
    const replayed = try run(gpa, &again.writer, .synthetic, seed, .{ .seeds = 1 });
    try std.testing.expectEqual(@as(u32, 1), replayed.failures);
}

test "the real targets pass a few seeds" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for ([_]Target{ .compile, .play, .save }) |target| {
        const summary = try run(gpa, &out.writer, target, 1, .{ .seeds = 8 });
        try std.testing.expectEqual(@as(u32, 0), summary.failures);
    }
}

test "the summary counts what the runs reached, and the run prints it" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const summary = try run(gpa, &out.writer, .play, 1, .{ .seeds = 16 });
    try std.testing.expect(summary.lines > 0);
    try std.testing.expect(summary.compile_failures + summary.runtime_errors <= summary.runs);
    var codes: u32 = summary.codes.other;
    for (summary.codes.counts[0..summary.codes.len]) |count| codes += count;
    try std.testing.expectEqual(summary.compile_failures, codes);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "swarm play: 16 runs, 0 failures; " ++
        "compile failures ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "step cap ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "ended ") != null);
    // P18.3: most seeds play a second time under fitted or tight limits.
    try std.testing.expect(summary.limited_runs * 2 > summary.runs - summary.compile_failures);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "limited runs ") != null);
}

test "played stories make many choices and reach the step cap, and some still end" {
    // P18.2: with `hub` and `typed`, the compiled stories of 500 seeds make 8 choices or
    // more on average, 40% or more reach the step cap, and 10% or more end (at END or DONE,
    // or out of content) without an error. P18.3: `e0` is bound or allowed its fallback in
    // 3 of 4 seeds, so at most 1 in 8 stops for a missing binding (none with `e0` bound: the
    // run fails then).
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const summary = try run(gpa, &out.writer, .play, 1, .{ .seeds = 500 });
    try std.testing.expectEqual(@as(u32, 0), summary.failures);
    const compiled = summary.runs - summary.compile_failures;
    try std.testing.expect(compiled > 400);
    try std.testing.expect(summary.choices >= 8 * @as(u64, compiled));
    try std.testing.expect(summary.step_cap * 100 >= compiled * 40);
    try std.testing.expect(summary.unbound_externals * 8 <= compiled);
    try std.testing.expect(summary.ended * 10 >= compiled);
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
