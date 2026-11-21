//! Swarm triage (Groce et al., "Swarm Testing", §5): over many seeded runs, which features
//! are on in every failing run (a *trigger*: the failure needs it) and which are off in every
//! failing run while passing runs use them (a *suppressor*: it hides the failure).

const std = @import("std");
const assert = std.debug.assert;
const fuzz_ink = @import("fuzz_ink.zig");
const Swarm = fuzz_ink.Swarm;

/// One feature: a key of one of the swarm's sets.
pub const Feature = struct { field: []const u8, key: []const u8 };

const features_max = 128;

pub const Triage = struct {
    /// How often each feature was on, in failing and in passing runs, by `feature_index`.
    on_failing: [features_max]u32 = @splat(0),
    on_passing: [features_max]u32 = @splat(0),
    failing: u32 = 0,
    passing: u32 = 0,

    pub fn add(triage: *Triage, swarm: Swarm, failed: bool) void {
        const counts = if (failed) &triage.on_failing else &triage.on_passing;
        if (failed) triage.failing += 1 else triage.passing += 1;
        var position: u32 = 0;
        inline for (@typeInfo(Swarm).@"struct".field_names) |name| {
            if (@FieldType(Swarm, name) != u8) {
                const Key = @FieldType(Swarm, name).Key;
                inline for (comptime std.enums.values(Key)) |key| {
                    if (@field(swarm, name).contains(key)) counts[position] += 1;
                    position += 1;
                }
            }
        }
        assert(position <= features_max);
    }

    /// Writes the triggers and the suppressors, one line each.
    pub fn report(triage: *const Triage, writer: *std.Io.Writer) !void {
        assert(triage.failing + triage.passing > 0 or triage.failing == 0);
        if (triage.failing == 0) return writer.writeAll("triage: no failing runs\n");
        try writer.print("triage over {d} failing and {d} passing runs\n", .{
            triage.failing,
            triage.passing,
        });
        var position: u32 = 0;
        inline for (@typeInfo(Swarm).@"struct".field_names) |name| {
            if (@FieldType(Swarm, name) != u8) {
                const Key = @FieldType(Swarm, name).Key;
                inline for (comptime std.enums.values(Key)) |key| {
                    const in_failing = triage.on_failing[position];
                    const in_passing = triage.on_passing[position];
                    if (in_failing == triage.failing and in_passing < triage.passing) {
                        try writer.print("trigger: {s}.{s}\n", .{ name, @tagName(key) });
                    }
                    if (in_failing == 0 and in_passing > 0) {
                        try writer.print("suppressor: {s}.{s}\n", .{ name, @tagName(key) });
                    }
                    position += 1;
                }
            }
        }
    }
};

test "triage names the features every failure has and the ones no failure has" {
    // Synthetic outcomes: runs fail exactly when glue is on and RANDOM is off. Over drawn
    // configurations, glue is the trigger and RANDOM a suppressor; nothing else is either.
    var triage: Triage = .{};
    for (0..400) |seed| {
        var prng: std.Random.DefaultPrng = .init(seed);
        const swarm = Swarm.draw(.{ .random = prng.random() });
        const failed = swarm.lines.contains(.glue) and !swarm.terms.contains(.random);
        triage.add(swarm, failed);
    }
    try std.testing.expect(triage.failing > 0 and triage.passing > 0);
    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    try triage.report(&text.writer);
    const written = text.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "trigger: lines.glue\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "suppressor: terms.random\n") != null);
    var lines = std.mem.splitScalar(u8, written, '\n');
    var named: u32 = 0;
    while (lines.next()) |line| {
        const trigger = std.mem.startsWith(u8, line, "trigger: ");
        if (trigger or std.mem.startsWith(u8, line, "suppressor: ")) named += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), named);
}
