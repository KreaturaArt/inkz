//! Reduction of a failing case, shared by `swarm-reduce` (the differential run,
//! src/swarm_differential.zig) and `swarm --reduce` (any swarm target, `swarm_reduce.zig`):
//! - `features` drops one swarm feature at a time while the failure stays (delta debugging
//!   over features: one oracle call per feature);
//! - `lines` drops chunks of a source's lines, halving the chunks down to single lines,
//!   while the failure stays.
//! An oracle is a pointer to a value with `keeps(candidate) !bool`: whether the candidate
//! still fails as the case did. Both stop at their `Bound`, keeping what they had then.

const std = @import("std");
const assert = std.debug.assert;
const Swarm = @import("fuzz_ink.zig").Swarm;

/// How far a reduction goes: at most `calls_max` oracle calls, and none after `deadline`.
pub const Bound = struct {
    calls_max: u32,
    deadline: ?std.Io.Timestamp = null,
    io: ?std.Io = null,

    fn exhausted(bound: Bound, calls: u32) bool {
        assert((bound.deadline == null) == (bound.io == null));
        if (calls >= bound.calls_max) return true;
        const deadline = bound.deadline orelse return false;
        return std.Io.Timestamp.now(bound.io.?, .awake).nanoseconds >= deadline.nanoseconds;
    }
};

// Feature-level reduction.

/// A bound's least value: no extra globals, and one of everything else.
fn bound_least(comptime name: []const u8) u8 {
    return if (comptime std.mem.eql(u8, name, "globals_extra")) 0 else 1;
}

/// The features `swarm` has on: its sets' keys, and its bounds above their least value.
pub fn features_count(swarm: Swarm) u32 {
    var count: u32 = 0;
    inline for (@typeInfo(Swarm).@"struct".field_names) |name| {
        const value = @field(swarm, name);
        if (@FieldType(Swarm, name) == u8) {
            count += @intFromBool(value > bound_least(name));
        } else {
            count += @intCast(value.count());
        }
    }
    return count;
}

pub const Reduction = struct {
    swarm: Swarm,
    /// Calls of the oracle, the first one included.
    calls: u32,
    /// Whether the bound stopped it before it tried every feature.
    stopped: bool,
};

/// Removes one feature at a time (a set key, or a bound lowered to its least value) and keeps
/// each removal after which `oracle.keeps(candidate)` still holds. One call per feature,
/// plus the first, which confirms the failure. The candidates aren't normalized: the
/// oracle normalizes what it generates.
pub fn features(start: Swarm, oracle: anytype, bound: Bound) !Reduction {
    assert(bound.calls_max > 0);
    var calls: u32 = 1;
    if (!try oracle.keeps(start)) return error.NoFailure;
    var current = start;
    var stopped = false;
    inline for (@typeInfo(Swarm).@"struct".field_names) |name| {
        if (@FieldType(Swarm, name) == u8) {
            if (@field(current, name) > bound_least(name)) {
                var candidate = current;
                @field(candidate, name) = bound_least(name);
                if (bound.exhausted(calls)) {
                    stopped = true;
                } else {
                    calls += 1;
                    if (try oracle.keeps(candidate)) current = candidate;
                }
            }
        } else {
            const keys = @field(current, name);
            var iterator = keys.iterator();
            while (iterator.next()) |key| {
                var candidate = current;
                @field(candidate, name).remove(key);
                if (bound.exhausted(calls)) {
                    stopped = true;
                    break;
                }
                calls += 1;
                if (try oracle.keeps(candidate)) current = candidate;
            }
        }
    }
    assert(calls <= features_count(start) + 1);
    return .{ .swarm = current, .calls = calls, .stopped = stopped };
}

// Line-level reduction.

pub const LinesReduction = struct {
    /// The reduced source, in the caller's buffer.
    source: []const u8,
    calls: u32,
    stopped: bool,
};

/// Removes chunks of `source`'s lines (each with its newline) while `oracle.keeps(text)`
/// holds: chunks of half the lines first, halved after each pass, then single lines until a
/// pass removes none. Each candidate is written to `buffer`, which ends holding the result;
/// `oracle.keeps` gets a view of it, valid during the call. Allocates the line table only.
pub fn lines(
    gpa: std.mem.Allocator,
    source: []const u8,
    buffer: []u8,
    oracle: anytype,
    bound: Bound,
) !LinesReduction {
    assert(bound.calls_max > 0);
    assert(buffer.len >= source.len);
    const starts = try line_starts(gpa, source);
    defer gpa.free(starts);
    // `kept[0..kept_len]` are the lines kept, by their index in `starts`.
    const kept = try gpa.alloc(u32, starts.len - 1);
    defer gpa.free(kept);
    for (kept, 0..) |*line, index| line.* = @intCast(index);
    var kept_len: u32 = @intCast(kept.len);

    var calls: u32 = 1;
    if (!try oracle.keeps(join(source, starts, kept[0..kept_len], buffer))) {
        return error.NoFailure;
    }
    var stopped = false;
    var chunk: u32 = @max(1, kept_len / 2);
    while (kept_len > 0 and !stopped) {
        var removed_any = false;
        var first: u32 = 0;
        while (first < kept_len) {
            if (bound.exhausted(calls)) {
                stopped = true;
                break;
            }
            const end = @min(first + chunk, kept_len);
            const candidate = join_without(source, starts, kept[0..kept_len], first, end, buffer);
            calls += 1;
            if (try oracle.keeps(candidate)) {
                // The lines after the chunk move up into its place.
                std.mem.copyForwards(u32, kept[first..], kept[end..kept_len]);
                kept_len -= end - first;
                removed_any = true;
            } else first = end;
        }
        if (chunk > 1) {
            chunk /= 2;
        } else if (!removed_any) break;
    }
    return .{
        .source = join(source, starts, kept[0..kept_len], buffer),
        .calls = calls,
        .stopped = stopped,
    };
}

/// Where each line of `source` starts, and its end last: `lines + 1` offsets.
fn line_starts(gpa: std.mem.Allocator, source: []const u8) ![]u32 {
    var count: u32 = 1;
    for (source, 0..) |byte, offset| {
        if (byte == '\n' and offset + 1 < source.len) count += 1;
    }
    if (source.len == 0) count = 0;
    const starts = try gpa.alloc(u32, count + 1);
    var line: u32 = 0;
    if (count > 0) starts[0] = 0;
    for (source, 0..) |byte, offset| {
        if (byte == '\n' and offset + 1 < source.len) {
            line += 1;
            starts[line] = @intCast(offset + 1);
        }
    }
    starts[count] = @intCast(source.len);
    return starts;
}

fn join(source: []const u8, starts: []const u32, kept: []const u32, buffer: []u8) []const u8 {
    return join_without(source, starts, kept, 0, 0, buffer);
}

/// The kept lines but `kept[first..end]`, joined in `buffer`.
fn join_without(
    source: []const u8,
    starts: []const u32,
    kept: []const u32,
    first: u32,
    end: u32,
    buffer: []u8,
) []const u8 {
    assert(first <= end and end <= kept.len);
    var length: usize = 0;
    for (kept, 0..) |line, position| {
        if (position >= first and position < end) continue;
        const text = source[starts[line]..starts[line + 1]];
        @memcpy(buffer[length..][0..text.len], text);
        length += text.len;
    }
    return buffer[0..length];
}

// Tests.

test "the feature reducer keeps exactly the features a failure needs" {
    // A fake oracle that fails when `choice` lines and the `has` operator are both on:
    // from the full mix, the reduction keeps those two and nothing else, within one call per
    // feature plus one.
    const Fake = struct {
        calls: u32 = 0,
        fn keeps(fake: *@This(), swarm: Swarm) !bool {
            fake.calls += 1;
            return swarm.lines.contains(.choice) and swarm.operators.contains(.has);
        }
    };
    var fake: Fake = .{};
    const reduction = try features(Swarm.all, &fake, .{ .calls_max = 1000 });
    try std.testing.expectEqual(fake.calls, reduction.calls);
    try std.testing.expect(!reduction.stopped);
    try std.testing.expect(reduction.calls <= features_count(Swarm.all) + 1);
    var expected = Swarm.none;
    expected.lines = .initOne(.choice);
    expected.operators = .initOne(.has);
    expected.lines_max = 1;
    expected.terms_max = 1;
    expected.choice_depth_max = 1;
    expected.knots_count = 1;
    try std.testing.expect(reduction.swarm.eql(expected));
    try std.testing.expectEqual(@as(u32, 2), features_count(reduction.swarm));
    var never: struct {
        fn keeps(_: *@This(), _: Swarm) !bool {
            return false;
        }
    } = .{};
    const bound: Bound = .{ .calls_max = 1000 };
    try std.testing.expectError(error.NoFailure, features(Swarm.all, &never, bound));
    // A bound of 5 calls stops it, with what it had.
    fake = .{};
    const bounded = try features(Swarm.all, &fake, .{ .calls_max = 5 });
    try std.testing.expect(bounded.stopped);
    try std.testing.expectEqual(@as(u32, 5), bounded.calls);
}

test "the line reducer keeps the lines a failure needs, within its bound" {
    // A fake oracle that fails while the text has a line `b` and an `e` after it: of 26 lines,
    // the two lines are left; a past deadline stops it after the first call, unchanged.
    const Fake = struct {
        fn keeps(_: *@This(), text: []const u8) !bool {
            const b = std.mem.indexOf(u8, text, "b\n") orelse return false;
            return std.mem.indexOfScalarPos(u8, text, b, 'e') != null;
        }
    };
    const gpa = std.testing.allocator;
    var source: [52]u8 = undefined;
    for (0..26) |index| {
        source[2 * index] = 'a' + @as(u8, @intCast(index));
        source[2 * index + 1] = '\n';
    }
    var buffer: [52]u8 = undefined;
    var fake: Fake = .{};
    const reduction = try lines(gpa, &source, &buffer, &fake, .{ .calls_max = 1000 });
    try std.testing.expectEqualStrings("b\ne\n", reduction.source);
    try std.testing.expect(!reduction.stopped);
    try std.testing.expect(reduction.calls < 60);
    const io = std.testing.io;
    const past: Bound = .{ .calls_max = 1000, .deadline = .now(io, .awake), .io = io };
    const stopped = try lines(gpa, &source, &buffer, &fake, past);
    try std.testing.expect(stopped.stopped);
    try std.testing.expectEqual(@as(u32, 1), stopped.calls);
    try std.testing.expectEqualStrings(&source, stopped.source);
    // A last line without a newline is a line too.
    const unended = try lines(gpa, "x\nb\ny\ne", &buffer, &fake, .{ .calls_max = 1000 });
    try std.testing.expectEqualStrings("b\ne", unended.source);
}
