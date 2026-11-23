//! The oracle: compares a story's transcript with the expected one, line by line, and
//! reports the first differing turn. Blank lines don't count, and `save:` lines compare as
//! JSON (key order ignored). There is no list of accepted differences: every corpus must
//! match exactly.

const std = @import("std");
const assert = std.debug.assert;

const file_bytes_max = 16 * 1024 * 1024;

/// One case's expected and actual transcripts.
pub const Result = struct {
    case: []const u8,
    expected: []const u8,
    actual: []const u8,
};

/// The gate: prints every case that differs, with its first difference, and fails if any does.
pub fn check(arena: std.mem.Allocator, corpus: []const u8, results: []const Result) !void {
    var differing: u32 = 0;
    for (results) |result| {
        const difference = try compare(arena, result.expected, result.actual) orelse continue;
        std.debug.print("{s}: {s}: {s}\n", .{ corpus, result.case, difference });
        differing += 1;
    }
    assert(differing <= results.len);
    std.debug.print("{s}: {d} cases, {d} differ\n", .{ corpus, results.len, differing });
    if (differing > 0) return error.OracleMismatch;
}

/// Null when `actual` matches `expected`; otherwise where they first differ:
/// `turn T, line N: expected ... | got ...`, with N a line of `expected`.
pub fn compare(arena: std.mem.Allocator, expected: []const u8, actual: []const u8) !?[]const u8 {
    assert(expected.len < file_bytes_max);
    assert(actual.len < file_bytes_max);
    var expected_lines = std.mem.splitScalar(u8, expected, '\n');
    var actual_lines = std.mem.splitScalar(u8, actual, '\n');
    var number: u32 = 0;
    var turn: u32 = 1;
    while (true) {
        const a = next_significant(&expected_lines, &number);
        const b = next_significant(&actual_lines, null);
        if (a == null and b == null) return null;
        if (a != null and b != null and try line_equivalent(arena, a.?, b.?)) {
            // A turn ends with a choice, made by `play` or by a `choose` action.
            const choice = std.mem.startsWith(u8, a.?, "choose: ") or
                std.mem.startsWith(u8, a.?, "> choose ");
            if (choice) turn += 1;
            continue;
        }
        return try std.fmt.allocPrint(arena, "turn {d}, line {d}: expected {s} | got {s}", .{
            turn, number, truncate(a orelse "<end>", 80), truncate(b orelse "<end>", 80),
        });
    }
}

/// The next non-blank line; `number` counts every line read.
fn next_significant(lines: *std.mem.SplitIterator(u8, .scalar), number: ?*u32) ?[]const u8 {
    while (lines.next()) |line| {
        if (number) |count| count.* += 1;
        if (line.len > 0) return line;
    }
    return null;
}

fn line_equivalent(arena: std.mem.Allocator, a: []const u8, b: []const u8) !bool {
    if (std.mem.eql(u8, a, b)) return true;
    if (!std.mem.startsWith(u8, a, "save: ") or !std.mem.startsWith(u8, b, "save: ")) return false;
    return json_equivalent(arena, a["save: ".len..], b["save: ".len..]);
}

pub fn json_equivalent(arena: std.mem.Allocator, a: []const u8, b: []const u8) !bool {
    assert(a.len < file_bytes_max);
    assert(b.len < file_bytes_max);
    const value_a = std.json.parseFromSliceLeaky(std.json.Value, arena, a, .{}) catch return false;
    const value_b = std.json.parseFromSliceLeaky(std.json.Value, arena, b, .{}) catch return false;
    return json_values_equal(value_a, value_b);
}

/// Deep equality where object key order doesn't matter. Iterative, with an explicit stack.
fn json_values_equal(a: std.json.Value, b: std.json.Value) bool {
    var pending: [256][2]std.json.Value = undefined;
    var count: u32 = 1;
    pending[0] = .{ a, b };
    var steps: u32 = 0;
    while (count > 0) : (steps += 1) {
        // Each value is visited once; a save holds far fewer than a million values.
        assert(steps < 1_000_000);
        assert(count <= pending.len);
        count -= 1;
        const left, const right = pending[count];
        if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
        switch (left) {
            .array => |items| {
                if (items.items.len != right.array.items.len) return false;
                for (items.items, right.array.items) |x, y| {
                    if (count == pending.len) return false;
                    pending[count] = .{ x, y };
                    count += 1;
                }
            },
            .object => |object| {
                if (object.count() != right.object.count()) return false;
                var iterator = object.iterator();
                while (iterator.next()) |entry| {
                    const other = right.object.get(entry.key_ptr.*) orelse return false;
                    if (count == pending.len) return false;
                    pending[count] = .{ entry.value_ptr.*, other };
                    count += 1;
                }
            },
            .string => |text| if (!std.mem.eql(u8, text, right.string)) return false,
            .number_string => |text| if (!std.mem.eql(u8, text, right.number_string)) return false,
            else => if (!std.meta.eql(left, right)) return false,
        }
    }
    return true;
}

fn truncate(text: []const u8, length: usize) []const u8 {
    assert(length > 0);
    const result = text[0..@min(text.len, length)];
    assert(result.len <= length);
    return result;
}

test "a differing pair reports the first differing turn" {
    // Two hand-made transcripts that agree on the first turn and differ on the second,
    // with a blank line that doesn't count; and one that stops early.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const expected = "> play\ntext: \"a\\n\"\nchoose: 0\ntext: \"b\\n\"\nend\n";
    const actual = "> play\n\ntext: \"a\\n\"\nchoose: 0\ntext: \"c\\n\"\nend\n";
    try std.testing.expectEqualStrings(
        "turn 2, line 4: expected text: \"b\\n\" | got text: \"c\\n\"",
        (try compare(arena, expected, actual)).?,
    );
    const short = "> play\ntext: \"a\\n\"\nchoose: 0\n";
    try std.testing.expectEqualStrings(
        "turn 2, line 4: expected text: \"b\\n\" | got <end>",
        (try compare(arena, expected, short)).?,
    );
    try std.testing.expectEqual(@as(?[]const u8, null), try compare(arena, expected, expected));
    const results = [_]Result{.{ .case = "seeded", .expected = expected, .actual = actual }};
    try std.testing.expectError(error.OracleMismatch, check(arena, "test", &results));
}

test "save lines compare as JSON, ignoring key order" {
    // JSON-equivalent saves: the same object with keys in another order.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = "save: {\"a\":1,\"b\":[true,\"x\"]}\n";
    const b = "save: {\"b\":[true,\"x\"],\"a\":1}\n";
    try std.testing.expectEqual(@as(?[]const u8, null), try compare(arena, a, b));
    const c = "save: {\"b\":[true,\"y\"],\"a\":1}\n";
    try std.testing.expect(try compare(arena, a, c) != null);
}
